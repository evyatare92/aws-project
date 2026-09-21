ifndef AWS_REGION
AWS_REGION := $(shell aws configure get region)
endif

PROJECT     ?= aws-project
ENV         ?= dev
# multi-az places a VPC endpoint ENI per AZ (~3x interface cost vs single-az).
ENDPOINT_AZ ?= multi-az

INFRA       := infra

# Staged into the artifacts bucket for the bastion, which has no internet access.
KUBECTL_VERSION ?= v1.36.0
HELM_VERSION    ?= v3.16.3

STACK_PREFIX := $(PROJECT)-$(ENV)

# Container apps: source in app/<name>/, ECR repo $(STACK_PREFIX)/<name>.
# Add a name here and a matching repository in infra/15-registry/ecr.yaml.
APPS := main weather
APP  ?= main

CHART_DIR  := deploy/charts
MAIN_CHART  := $(CHART_DIR)/main/Chart.yaml
MAIN_VALUES := $(CHART_DIR)/main/values.yaml
# Helm release for the main app, and the namespace it lives in.
RELEASE    ?= weather-main
NAMESPACE  ?= weather
LOCAL_PORT ?= 8080
# Public Gateway ALB source. Empty means "detect this machine's public IP".
CLIENT_CIDR ?=
LBC_CHART_VERSION    ?= 3.5.0
GATEWAY_API_VERSION  ?= v1.2.1
LBC_NAMESPACE        ?= kube-system
LBC_SA               ?= aws-load-balancer-controller

AWS_ACCOUNT_ID := $(shell aws sts get-caller-identity --query Account --output text 2>/dev/null)
ECR_REGISTRY   := $(AWS_ACCOUNT_ID).dkr.ecr.$(AWS_REGION).amazonaws.com
APP_DIR        := app/$(APP)
IMAGE_TAG      := $(shell cat $(APP_DIR)/.version 2>/dev/null)
ECR_URI        := $(ECR_REGISTRY)/$(STACK_PREFIX)/$(APP)
DEPLOY := aws cloudformation deploy --region $(AWS_REGION) \
	--no-fail-on-empty-changeset \
	--capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM \
	--tags Project=$(PROJECT) Environment=$(ENV) ManagedBy=cloudformation

COMMON_PARAMS := ProjectName=$(PROJECT) Environment=$(ENV)

.PHONY: all bootstrap registry network endpoints eks ecs lambda lambda-agent-package lambda-sqs-package bastion bastion-tools connect lint outputs \
	app-login app-build version-bump app-push app-publish app-image app-push-all \
	charts-version charts-stage \
	app-deploy app-helm app-forward alb lbc lbc-iam lbc-stage lbc-install \
	destroy-registry destroy-eks destroy-ecs destroy-ecs-weather destroy-lambda destroy-bastion destroy-alb destroy-lbc destroy-network destroy-nat

# Order matters: nat adds IGW routes; endpoints need the VPC; compute needs both.
all: bootstrap registry network nat endpoints eks ecs ecs-weather lambda bastion app-deploy

bootstrap:
	$(DEPLOY) --stack-name $(STACK_PREFIX)-bootstrap \
		--template-file $(INFRA)/00-bootstrap/artifacts.yaml \
		--parameter-overrides $(COMMON_PARAMS)

registry:
	$(DEPLOY) --stack-name $(STACK_PREFIX)-registry \
		--template-file $(INFRA)/15-registry/ecr.yaml \
		--parameter-overrides $(COMMON_PARAMS)

network:
	$(DEPLOY) --stack-name $(STACK_PREFIX)-vpc \
		--template-file $(INFRA)/10-network/vpc.yaml \
		--parameter-overrides $(COMMON_PARAMS)

nat:
	$(DEPLOY) --stack-name $(STACK_PREFIX)-nat \
		--template-file $(INFRA)/10-network/nat.yaml \
		--parameter-overrides $(COMMON_PARAMS)

endpoints:
	$(DEPLOY) --stack-name $(STACK_PREFIX)-endpoints \
		--template-file $(INFRA)/10-network/endpoints.yaml \
		--parameter-overrides $(COMMON_PARAMS) EndpointAvailability=$(ENDPOINT_AZ)

eks:
	$(DEPLOY) --stack-name $(STACK_PREFIX)-eks \
		--template-file $(INFRA)/20-eks/cluster.yaml \
		--parameter-overrides $(COMMON_PARAMS) NodeMinSize=2 NodeDesiredCapacity=2

ecs:
	$(DEPLOY) --stack-name $(STACK_PREFIX)-ecs \
		--template-file $(INFRA)/30-ecs/cluster.yaml \
		--parameter-overrides $(COMMON_PARAMS)

ecs-weather:
	$(DEPLOY) --stack-name $(STACK_PREFIX)-ecs-weather \
		--template-file $(INFRA)/31-ecs/weather-service.yaml \
		--parameter-overrides $(COMMON_PARAMS) ImageTag=$(shell cat app/weather/.version) DesiredCount=2

AGENT_DIR     := app/agent
AGENT_S3_KEY  := lambda/agent/handler.zip
ANTHROPIC_API_KEY ?=

lambda-agent-package:
	@test -f $(AGENT_DIR)/handler.py || { echo "Missing $(AGENT_DIR)/handler.py"; exit 1; }
	@test -f $(AGENT_DIR)/requirements.txt || { echo "Missing $(AGENT_DIR)/requirements.txt"; exit 1; }
	rm -rf .build/agent .build/handler.zip
	mkdir -p .build/agent
	python3 -m pip install -q -r $(AGENT_DIR)/requirements.txt -t .build/agent \
		--python-version 3.13 --platform manylinux2014_x86_64 --implementation cp \
		--only-binary=:all: --ignore-installed
	cp $(AGENT_DIR)/handler.py .build/agent/handler.py
	find .build/agent -type d -name '__pycache__' -prune -exec rm -rf {} +
	cd .build/agent && zip -qr ../handler.zip . -x '*.pyc'
	aws s3 cp .build/handler.zip s3://$(ARTIFACTS_BUCKET)/$(AGENT_S3_KEY) --region $(AWS_REGION)
	rm -rf .build
	@echo "Uploaded s3://$(ARTIFACTS_BUCKET)/$(AGENT_S3_KEY)"

SQS_DIR    := app/sqs-weather
SQS_S3_KEY := lambda/sqs-weather/handler.zip

lambda-sqs-package:
	@test -f $(SQS_DIR)/handler.py || { echo "Missing $(SQS_DIR)/handler.py"; exit 1; }
	rm -rf .build
	mkdir -p .build/sqs
	cp $(SQS_DIR)/handler.py .build/sqs/handler.py
	cd .build/sqs && zip -qr ../sqs-weather.zip handler.py
	aws s3 cp .build/sqs-weather.zip s3://$(ARTIFACTS_BUCKET)/$(SQS_S3_KEY) --region $(AWS_REGION)
	rm -rf .build
	@echo "Uploaded s3://$(ARTIFACTS_BUCKET)/$(SQS_S3_KEY)"

lambda: lambda-agent-package lambda-sqs-package
	@agent_ver=$$(aws s3api head-object --region $(AWS_REGION) --bucket $(ARTIFACTS_BUCKET) \
		--key $(AGENT_S3_KEY) --query VersionId --output text) && \
	sqs_ver=$$(aws s3api head-object --region $(AWS_REGION) --bucket $(ARTIFACTS_BUCKET) \
		--key $(SQS_S3_KEY) --query VersionId --output text) && \
	params="$(COMMON_PARAMS) AgentCodeS3Key=$(AGENT_S3_KEY) AgentCodeS3ObjectVersion=$$agent_ver SqsCodeS3Key=$(SQS_S3_KEY) SqsCodeS3ObjectVersion=$$sqs_ver" && \
	if [ -n "$(ANTHROPIC_API_KEY)" ]; then params="$$params AnthropicApiKey=$(ANTHROPIC_API_KEY)"; fi && \
	$(DEPLOY) --stack-name $(STACK_PREFIX)-lambda \
		--template-file $(INFRA)/40-lambda/functions.yaml \
		--parameter-overrides $$params && \
	api=$$(aws cloudformation describe-stacks --region $(AWS_REGION) \
		--stack-name $(STACK_PREFIX)-lambda \
		--query 'Stacks[0].Outputs[?OutputKey==`PrivateApiId`].OutputValue' --output text) && \
	aws apigateway create-deployment --region $(AWS_REGION) --rest-api-id $$api \
		--stage-name v1 --description "agent $$agent_ver sqs $$sqs_ver" >/dev/null && \
	echo "Lambda agent and SQS weather function deployed. Pass ANTHROPIC_API_KEY=... if the secret is still empty."

# Deploy after eks, so the cluster exports the bastion's access entry needs exist.
bastion:
	$(DEPLOY) --stack-name $(STACK_PREFIX)-bastion \
		--template-file $(INFRA)/50-bastion/bastion.yaml \
		--parameter-overrides $(COMMON_PARAMS)

ARTIFACTS_BUCKET = $(shell aws cloudformation describe-stacks --region $(AWS_REGION) \
	--stack-name $(STACK_PREFIX)-bootstrap \
	--query 'Stacks[0].Outputs[?OutputKey==`ArtifactsBucketName`].OutputValue' --output text)

BASTION_ID = $(shell aws cloudformation describe-stacks --region $(AWS_REGION) \
	--stack-name $(STACK_PREFIX)-bastion \
	--query 'Stacks[0].Outputs[?OutputKey==`BastionInstanceId`].OutputValue' --output text)

app-login:
	@test -n "$(ECR_REGISTRY)" || (echo "Configure AWS credentials." && exit 1)
	aws ecr get-login-password --region $(AWS_REGION) \
		| docker login --username AWS --password-stdin $(ECR_REGISTRY)

app-build:
	@test -n "$(filter $(APP),$(APPS))" || (echo "Unknown APP '$(APP)'. Registered: $(APPS)" && exit 1)
	@test -f "$(APP_DIR)/Dockerfile" || (echo "Missing $(APP_DIR)/Dockerfile" && exit 1)
	@test -n "$(IMAGE_TAG)" || (echo "Missing $(APP_DIR)/.version" && exit 1)
	docker build -t $(ECR_URI):$(IMAGE_TAG) -t $(ECR_URI):latest $(APP_DIR)

# Every push is a new release, so the patch number moves first.
version-bump:
	@f=$(APP_DIR)/.version; \
	test -f "$$f" || { echo "Missing $$f"; exit 1; }; \
	v=$$(tr -d '[:space:]' < "$$f"); \
	patch=$${v##*.}; \
	case "$$v" in *.*.*) ;; *) echo "Want MAJOR.MINOR.PATCH in $$f, found '$$v'"; exit 1;; esac; \
	case "$$patch" in ''|*[!0-9]*) echo "Non-numeric patch in '$$v'"; exit 1;; esac; \
	printf '%s\n' "$${v%.*}.$$((patch + 1))" > "$$f"; \
	echo "$$f: $$v -> $$(cat $$f)"

# IMAGE_TAG is expanded when make starts, so the push has to run in a fresh
# make for the bumped version to be picked up.
app-push: version-bump
	@$(MAKE) --no-print-directory app-publish APP=$(APP)

app-publish: app-login app-build
	docker push $(ECR_URI):$(IMAGE_TAG)
	docker push $(ECR_URI):latest
	@echo "Pushed $(ECR_URI):$(IMAGE_TAG) and $(ECR_URI):latest"

app-image: app-push

app-push-all: $(addprefix app-push-,$(APPS))

app-build-%:
	@$(MAKE) app-build APP=$*

app-push-%:
	@$(MAKE) app-push APP=$*

# Points the chart at whatever app/main/.version currently names, so a staged
# chart always ships the matching image instead of a mutable tag.
charts-version:
	@v=$$(tr -d '[:space:]' < app/main/.version) && \
	test -n "$$v" || { echo "app/main/.version is empty"; exit 1; } && \
	sed -i -E "s/^version:.*/version: $$v/" $(MAIN_CHART) && \
	sed -i -E "s/^appVersion:.*/appVersion: \"$$v\"/" $(MAIN_CHART) && \
	sed -i -E "/^image:/,/^[[:space:]]*$$/ s/^  tag:.*/  tag: \"$$v\"/" $(MAIN_VALUES) && \
	echo "chart version, appVersion and image tag set to $$v"
	@url=$$(aws cloudformation list-exports --region $(AWS_REGION) \
		--query "Exports[?Name=='$(STACK_PREFIX)-AgentApiUrl'].Value" --output text 2>/dev/null); \
	if [ -n "$$url" ] && [ "$$url" != "None" ]; then \
		sed -i -E "/^agent:/,/^[[:space:]]*$$/ s|^  serviceUrl:.*|  serviceUrl: $$url|" $(MAIN_VALUES); \
		echo "$(MAIN_VALUES): agent.serviceUrl set to $$url"; \
	fi
	@qurl=$$(aws cloudformation list-exports --region $(AWS_REGION) \
		--query "Exports[?Name=='$(STACK_PREFIX)-WorkQueueUrl'].Value" --output text 2>/dev/null); \
	if [ -n "$$qurl" ] && [ "$$qurl" != "None" ]; then \
		sed -i -E "/^queue:/,/^[[:space:]]*$$/ s|^  queueUrl:.*|  queueUrl: $$qurl|" $(MAIN_VALUES); \
		echo "$(MAIN_VALUES): queue.queueUrl set to $$qurl"; \
	fi
	@table=$$(aws cloudformation list-exports --region $(AWS_REGION) \
		--query "Exports[?Name=='$(STACK_PREFIX)-WeatherResultsTableName'].Value" --output text 2>/dev/null); \
	if [ -n "$$table" ] && [ "$$table" != "None" ]; then \
		sed -i -E "/^queue:/,/^[[:space:]]*$$/ s|^  resultsTable:.*|  resultsTable: $$table|" $(MAIN_VALUES); \
		echo "$(MAIN_VALUES): queue.resultsTable set to $$table"; \
	fi
	@role=$$(aws cloudformation list-exports --region $(AWS_REGION) \
		--query "Exports[?Name=='$(STACK_PREFIX)-MainAppRoleArn'].Value" --output text 2>/dev/null); \
	if [ -n "$$role" ] && [ "$$role" != "None" ]; then \
		sed -i -E "/^serviceAccount:/,/^[[:space:]]*$$/ s|^  roleArn:.*|  roleArn: $$role|" $(MAIN_VALUES); \
		echo "$(MAIN_VALUES): serviceAccount.roleArn set to $$role"; \
	fi
	@sed -i -E "s|^  loadBalancerName:.*|  loadBalancerName: $(STACK_PREFIX)-gw|" $(MAIN_VALUES)
	@a=$$(aws cloudformation list-exports --region $(AWS_REGION) \
		--query "Exports[?Name=='$(STACK_PREFIX)-NatPublicSubnetId'].Value" --output text 2>/dev/null); \
	b=$$(aws cloudformation list-exports --region $(AWS_REGION) \
		--query "Exports[?Name=='$(STACK_PREFIX)-AlbPublicSubnetBId'].Value" --output text 2>/dev/null); \
	c=$$(aws cloudformation list-exports --region $(AWS_REGION) \
		--query "Exports[?Name=='$(STACK_PREFIX)-AlbPublicSubnetCId'].Value" --output text 2>/dev/null); \
	if [ -n "$$a" ] && [ "$$a" != "None" ] && [ -n "$$b" ] && [ "$$b" != "None" ] && [ -n "$$c" ] && [ "$$c" != "None" ]; then \
		sed -i -E "s|^  subnetIds:.*|  subnetIds: \"$$a,$$b,$$c\"|" $(MAIN_VALUES); \
		echo "$(MAIN_VALUES): gateway.subnetIds set to $$a,$$b,$$c"; \
	fi
	@if [ -n "$(CLIENT_CIDR)" ]; then \
		sed -i -E "s|^  sourceRange:.*|  sourceRange: \"$(CLIENT_CIDR)\"|" $(MAIN_VALUES); \
		echo "$(MAIN_VALUES): gateway.sourceRange set to $(CLIENT_CIDR)"; \
	fi

# The bastion has no internet route, so charts travel via the artifacts bucket.
charts-stage: charts-version
	aws s3 sync $(CHART_DIR) s3://$(ARTIFACTS_BUCKET)/charts \
		--region $(AWS_REGION) --delete
	@echo "Staged charts to s3://$(ARTIFACTS_BUCKET)/charts"

# Installs the chart from the bastion, because the EKS API is private. SSM Run
# Command is the non-interactive counterpart to "make connect".
app-deploy: app-push charts-stage app-helm

app-helm:
	@test -n "$(BASTION_ID)" || { echo "No bastion found. Run 'make bastion'."; exit 1; }
	@echo "Deploying $(RELEASE) to namespace $(NAMESPACE) via $(BASTION_ID)"
	@cid=$$(aws ssm send-command --region $(AWS_REGION) \
		--instance-ids $(BASTION_ID) \
		--document-name AWS-RunShellScript \
		--timeout-seconds 1200 \
		--comment "helm deploy $(RELEASE)" \
		--parameters 'commands=["aws s3 cp s3://$(ARTIFACTS_BUCKET)/charts/bastion-deploy.sh /tmp/bastion-deploy.sh --region $(AWS_REGION)","BUCKET=$(ARTIFACTS_BUCKET) CLUSTER=$(STACK_PREFIX) REGION=$(AWS_REGION) RELEASE=$(RELEASE) NAMESPACE=$(NAMESPACE) bash /tmp/bastion-deploy.sh"]' \
		--query Command.CommandId --output text) && \
	test -n "$$cid" || { echo "send-command returned no command id" >&2; exit 1; }; \
	echo "SSM command $$cid"; \
	for _ in $$(seq 1 90); do \
		st=$$(aws ssm get-command-invocation --region $(AWS_REGION) \
			--command-id $$cid --instance-id $(BASTION_ID) \
			--query Status --output text 2>/dev/null) || st=Pending; \
		case "$$st" in Success|Failed|Cancelled|TimedOut) break ;; esac; \
		sleep 10; \
	done; \
	aws ssm get-command-invocation --region $(AWS_REGION) \
		--command-id $$cid --instance-id $(BASTION_ID) \
		--query StandardOutputContent --output text; \
	st=$$(aws ssm get-command-invocation --region $(AWS_REGION) \
		--command-id $$cid --instance-id $(BASTION_ID) \
		--query Status --output text); \
	if [ "$$st" != "Success" ]; then \
		aws ssm get-command-invocation --region $(AWS_REGION) \
			--command-id $$cid --instance-id $(BASTION_ID) \
			--query StandardErrorContent --output text >&2; \
		echo "Remote deploy finished with status: $$st" >&2; \
		exit 1; \
	fi; \
	echo "Deployed $(RELEASE) to namespace $(NAMESPACE)"

# Opens http://localhost:$(LOCAL_PORT) on your PC: starts kubectl port-forward
# on the bastion (ClusterIP), then SSM forwards to that listener. Ctrl-C stops
# the tunnel; the bastion port-forward may keep running until the next app-forward.
app-forward:
	@test -n "$(BASTION_ID)" || (echo "No bastion found. Run 'make bastion'." && exit 1)
	@aws s3 cp deploy/charts/bastion-port-forward.sh \
		s3://$(ARTIFACTS_BUCKET)/charts/bastion-port-forward.sh --region $(AWS_REGION) >/dev/null
	@cid=$$(aws ssm send-command --region $(AWS_REGION) \
		--instance-ids $(BASTION_ID) \
		--document-name AWS-RunShellScript \
		--timeout-seconds 120 \
		--comment "kubectl port-forward $(RELEASE)" \
		--parameters 'commands=["aws s3 cp s3://$(ARTIFACTS_BUCKET)/charts/bastion-port-forward.sh /tmp/bastion-port-forward.sh --region $(AWS_REGION)","CLUSTER=$(STACK_PREFIX) REGION=$(AWS_REGION) RELEASE=$(RELEASE) NAMESPACE=$(NAMESPACE) PF_PORT=$(LOCAL_PORT) bash /tmp/bastion-port-forward.sh"]' \
		--query Command.CommandId --output text) && \
	test -n "$$cid" || { echo "send-command returned no command id" >&2; exit 1; }; \
	echo "SSM command $$cid (port-forward on bastion)"; \
	for _ in $$(seq 1 24); do \
		st=$$(aws ssm get-command-invocation --region $(AWS_REGION) \
			--command-id $$cid --instance-id $(BASTION_ID) \
			--query Status --output text 2>/dev/null) || st=Pending; \
		case "$$st" in Success|Failed|Cancelled|TimedOut) break ;; esac; \
		sleep 2; \
	done; \
	aws ssm get-command-invocation --region $(AWS_REGION) \
		--command-id $$cid --instance-id $(BASTION_ID) \
		--query StandardOutputContent --output text; \
	st=$$(aws ssm get-command-invocation --region $(AWS_REGION) \
		--command-id $$cid --instance-id $(BASTION_ID) \
		--query Status --output text); \
	if [ "$$st" != "Success" ]; then \
		aws ssm get-command-invocation --region $(AWS_REGION) \
			--command-id $$cid --instance-id $(BASTION_ID) \
			--query StandardErrorContent --output text >&2; \
		echo "Port-forward setup finished with status: $$st" >&2; \
		exit 1; \
	fi; \
	echo "Forwarding localhost:$(LOCAL_PORT) -> bastion:127.0.0.1:$(LOCAL_PORT) via $(BASTION_ID)"; \
	aws ssm start-session --region $(AWS_REGION) --target $(BASTION_ID) \
		--document-name AWS-StartPortForwardingSessionToRemoteHost \
		--parameters host="127.0.0.1",portNumber="$(LOCAL_PORT)",localPortNumber="$(LOCAL_PORT)"

# Internet-facing ALB via Gateway API + AWS Load Balancer Controller, locked
# to CLIENT_CIDR (defaults to this PC). Not part of "make all".
alb: nat eks lbc
	@cidr="$(CLIENT_CIDR)"; \
	if [ -z "$$cidr" ]; then \
		ip=$$(curl -sS https://checkip.amazonaws.com | tr -d '[:space:]'); \
		test -n "$$ip" || { echo "Could not detect public IP. Pass CLIENT_CIDR=x.x.x.x/32"; exit 1; }; \
		cidr="$$ip/32"; \
	fi; \
	echo "Deploying Gateway ALB allowed from $$cidr"; \
	$(MAKE) --no-print-directory charts-stage app-helm CLIENT_CIDR=$$cidr

lbc-iam:
	$(DEPLOY) --stack-name $(STACK_PREFIX)-lbc \
		--template-file $(INFRA)/61-lbc/iam.yaml \
		--parameter-overrides $(COMMON_PARAMS)

# Pull the upstream LBC chart and Gateway API CRDs here (the bastion has no
# GitHub access in the original design), fill IRSA/VPC values, stage to S3.
lbc-stage: lbc-iam
	@rm -rf .build/lbc && mkdir -p .build/lbc/chart .build/tools
	@if command -v helm >/dev/null 2>&1; then h=helm; else \
		h=.build/tools/helm; \
		if [ ! -x $$h ]; then \
			curl -sSL "https://get.helm.sh/helm-$(HELM_VERSION)-linux-amd64.tar.gz" \
				| tar -xz -C .build/tools --strip-components=1 linux-amd64/helm; \
		fi; \
	fi; \
	$$h pull aws-load-balancer-controller \
		--repo https://aws.github.io/eks-charts \
		--version $(LBC_CHART_VERSION) \
		--untar --untardir .build/lbc && \
	rm -rf .build/lbc/chart && mv .build/lbc/aws-load-balancer-controller .build/lbc/chart
	curl -sSLo .build/lbc/gateway-api-crds.yaml \
		https://github.com/kubernetes-sigs/gateway-api/releases/download/$(GATEWAY_API_VERSION)/standard-install.yaml
	@cp deploy/charts/aws-load-balancer-controller/values.yaml .build/lbc/values.yaml
	@cp deploy/charts/bastion-lbc.sh .build/lbc/bastion-lbc.sh
	@vpc=$$(aws cloudformation list-exports --region $(AWS_REGION) \
		--query "Exports[?Name=='$(STACK_PREFIX)-VpcId'].Value" --output text) && \
	role=$$(aws cloudformation list-exports --region $(AWS_REGION) \
		--query "Exports[?Name=='$(STACK_PREFIX)-LbcRoleArn'].Value" --output text) && \
	test -n "$$vpc" -a "$$vpc" != "None" || { echo "No VpcId export. Run 'make network'."; exit 1; }; \
	test -n "$$role" -a "$$role" != "None" || { echo "No LbcRoleArn export. Run 'make lbc-iam'."; exit 1; }; \
	sed -i -E "s|^clusterName:.*|clusterName: $(STACK_PREFIX)|" .build/lbc/values.yaml; \
	sed -i -E "s|^region:.*|region: $(AWS_REGION)|" .build/lbc/values.yaml; \
	sed -i -E "s|^vpcId:.*|vpcId: $$vpc|" .build/lbc/values.yaml; \
	sed -i -E "s|eks.amazonaws.com/role-arn:.*|eks.amazonaws.com/role-arn: $$role|" .build/lbc/values.yaml; \
	echo "LBC values: cluster=$(STACK_PREFIX) region=$(AWS_REGION) vpc=$$vpc"
	aws s3 sync .build/lbc s3://$(ARTIFACTS_BUCKET)/lbc --region $(AWS_REGION) --delete
	@echo "Staged LBC chart to s3://$(ARTIFACTS_BUCKET)/lbc"

lbc-install: lbc-stage
	@test -n "$(BASTION_ID)" || { echo "No bastion found. Run 'make bastion'."; exit 1; }
	@echo "Installing AWS Load Balancer Controller via $(BASTION_ID)"
	@cid=$$(aws ssm send-command --region $(AWS_REGION) \
		--instance-ids $(BASTION_ID) \
		--document-name AWS-RunShellScript \
		--timeout-seconds 1800 \
		--comment "install aws-load-balancer-controller" \
		--parameters 'commands=["aws s3 cp s3://$(ARTIFACTS_BUCKET)/lbc/bastion-lbc.sh /tmp/bastion-lbc.sh --region $(AWS_REGION)","BUCKET=$(ARTIFACTS_BUCKET) CLUSTER=$(STACK_PREFIX) REGION=$(AWS_REGION) bash /tmp/bastion-lbc.sh"]' \
		--query Command.CommandId --output text) && \
	test -n "$$cid" || { echo "send-command returned no command id" >&2; exit 1; }; \
	echo "SSM command $$cid"; \
	for _ in $$(seq 1 120); do \
		st=$$(aws ssm get-command-invocation --region $(AWS_REGION) \
			--command-id $$cid --instance-id $(BASTION_ID) \
			--query Status --output text 2>/dev/null) || st=Pending; \
		case "$$st" in Success|Failed|Cancelled|TimedOut) break ;; esac; \
		sleep 10; \
	done; \
	aws ssm get-command-invocation --region $(AWS_REGION) \
		--command-id $$cid --instance-id $(BASTION_ID) \
		--query StandardOutputContent --output text; \
	st=$$(aws ssm get-command-invocation --region $(AWS_REGION) \
		--command-id $$cid --instance-id $(BASTION_ID) \
		--query Status --output text); \
	if [ "$$st" != "Success" ]; then \
		aws ssm get-command-invocation --region $(AWS_REGION) \
			--command-id $$cid --instance-id $(BASTION_ID) \
			--query StandardErrorContent --output text >&2; \
		echo "Remote LBC install finished with status: $$st" >&2; \
		exit 1; \
	fi; \
	echo "AWS Load Balancer Controller installed"

lbc: lbc-install

# The bastion has no internet route, so fetch tools here and push them to S3.
bastion-tools:
	@tmp=$$(mktemp -d) && \
	curl -sSLo $$tmp/kubectl "https://dl.k8s.io/release/$(KUBECTL_VERSION)/bin/linux/amd64/kubectl" && \
	curl -sSL "https://get.helm.sh/helm-$(HELM_VERSION)-linux-amd64.tar.gz" \
		| tar -xz -C $$tmp --strip-components=1 linux-amd64/helm && \
	aws s3 cp $$tmp/kubectl s3://$(ARTIFACTS_BUCKET)/bastion-tools/kubectl --region $(AWS_REGION) && \
	aws s3 cp $$tmp/helm s3://$(ARTIFACTS_BUCKET)/bastion-tools/helm --region $(AWS_REGION) && \
	rm -rf $$tmp && \
	echo "Staged kubectl $(KUBECTL_VERSION) and helm $(HELM_VERSION)"

connect:
	aws ssm start-session --region $(AWS_REGION) --target $(BASTION_ID)

lint:
	cfn-lint $(INFRA)/00-bootstrap/*.yaml $(INFRA)/15-registry/*.yaml $(INFRA)/10-network/*.yaml \
		$(INFRA)/20-eks/*.yaml $(INFRA)/30-ecs/*.yaml $(INFRA)/31-ecs/*.yaml $(INFRA)/40-lambda/*.yaml \
		$(INFRA)/50-bastion/*.yaml $(INFRA)/60-alb/*.yaml $(INFRA)/61-lbc/*.yaml

outputs:
	@aws cloudformation describe-stacks --region $(AWS_REGION) \
		--stack-name $(STACK_PREFIX)-vpc \
		--query 'Stacks[0].Outputs' --output table

destroy-registry:
	aws cloudformation delete-stack --region $(AWS_REGION) --stack-name $(STACK_PREFIX)-registry
	aws cloudformation wait stack-delete-complete --region $(AWS_REGION) --stack-name $(STACK_PREFIX)-registry

destroy-eks:
	aws cloudformation delete-stack --region $(AWS_REGION) --stack-name $(STACK_PREFIX)-eks
	aws cloudformation wait stack-delete-complete --region $(AWS_REGION) --stack-name $(STACK_PREFIX)-eks

destroy-ecs-weather:
	aws cloudformation delete-stack --region $(AWS_REGION) --stack-name $(STACK_PREFIX)-ecs-weather
	aws cloudformation wait stack-delete-complete --region $(AWS_REGION) --stack-name $(STACK_PREFIX)-ecs-weather

destroy-ecs: destroy-ecs-weather
	aws cloudformation delete-stack --region $(AWS_REGION) --stack-name $(STACK_PREFIX)-ecs
	aws cloudformation wait stack-delete-complete --region $(AWS_REGION) --stack-name $(STACK_PREFIX)-ecs

destroy-nat:
	aws cloudformation delete-stack --region $(AWS_REGION) --stack-name $(STACK_PREFIX)-nat
	aws cloudformation wait stack-delete-complete --region $(AWS_REGION) --stack-name $(STACK_PREFIX)-nat

destroy-lambda:
	aws cloudformation delete-stack --region $(AWS_REGION) --stack-name $(STACK_PREFIX)-lambda
	aws cloudformation wait stack-delete-complete --region $(AWS_REGION) --stack-name $(STACK_PREFIX)-lambda

# Must go before destroy-eks: this stack imports the cluster's exports.
destroy-bastion:
	aws cloudformation delete-stack --region $(AWS_REGION) --stack-name $(STACK_PREFIX)-bastion
	aws cloudformation wait stack-delete-complete --region $(AWS_REGION) --stack-name $(STACK_PREFIX)-bastion

destroy-alb:
	aws cloudformation delete-stack --region $(AWS_REGION) --stack-name $(STACK_PREFIX)-alb
	aws cloudformation wait stack-delete-complete --region $(AWS_REGION) --stack-name $(STACK_PREFIX)-alb

# Removes Gateway objects (so the controller can delete the ALB) then the LBC
# Helm release and its IAM role. Best-effort if the bastion is already gone.
destroy-lbc:
	@if [ -n "$(BASTION_ID)" ] && [ "$(BASTION_ID)" != "None" ]; then \
		cid=$$(aws ssm send-command --region $(AWS_REGION) \
			--instance-ids $(BASTION_ID) \
			--document-name AWS-RunShellScript \
			--timeout-seconds 900 \
			--comment "remove gateway and LBC" \
			--parameters 'commands=["export PATH=/usr/local/bin:$$PATH","export KUBECONFIG=/root/.kube/config","aws eks update-kubeconfig --name $(STACK_PREFIX) --region $(AWS_REGION) --kubeconfig /root/.kube/config","kubectl delete httproute,gateway -n $(NAMESPACE) --all --ignore-not-found || true","kubectl delete loadbalancerconfiguration,targetgroupconfiguration -n $(NAMESPACE) --all --ignore-not-found || true","helm uninstall aws-load-balancer-controller -n $(LBC_NAMESPACE) --wait --timeout 5m || true","kubectl delete gatewayclass aws-alb --ignore-not-found || true"]' \
			--query Command.CommandId --output text); \
		echo "SSM command $$cid"; \
		aws ssm wait command-executed --region $(AWS_REGION) \
			--command-id $$cid --instance-id $(BASTION_ID) >/dev/null 2>&1 || true; \
		aws ssm get-command-invocation --region $(AWS_REGION) \
			--command-id $$cid --instance-id $(BASTION_ID) \
			--query StandardOutputContent --output text; \
	else \
		echo "No bastion; skipping in-cluster LBC uninstall."; \
	fi
	aws cloudformation delete-stack --region $(AWS_REGION) --stack-name $(STACK_PREFIX)-lbc
	aws cloudformation wait stack-delete-complete --region $(AWS_REGION) --stack-name $(STACK_PREFIX)-lbc

# Endpoints must go before the VPC: the VPC's exports are in use until they do.
destroy-network: destroy-lbc destroy-alb destroy-bastion destroy-eks destroy-ecs destroy-lambda destroy-nat
	aws cloudformation delete-stack --region $(AWS_REGION) --stack-name $(STACK_PREFIX)-endpoints
	aws cloudformation wait stack-delete-complete --region $(AWS_REGION) --stack-name $(STACK_PREFIX)-endpoints
	aws cloudformation delete-stack --region $(AWS_REGION) --stack-name $(STACK_PREFIX)-vpc
