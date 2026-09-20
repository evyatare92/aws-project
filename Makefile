ifndef AWS_REGION
AWS_REGION := $(shell aws configure get region)
endif

PROJECT     ?= aws-project
ENV         ?= dev
# single-az keeps interface endpoint charges to ~1/3; use multi-az for prod.
ENDPOINT_AZ ?= single-az

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
# Must match service.nodePort in the chart and AppNodePort in the bastion stack.
NODE_PORT  ?= 30080
LOCAL_PORT ?= 8080
# Public ALB source. Empty means "detect this machine's public IP".
CLIENT_CIDR ?=

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
	app-deploy app-forward alb \
	destroy-registry destroy-eks destroy-ecs destroy-ecs-weather destroy-lambda destroy-bastion destroy-alb destroy-network destroy-nat

# Order matters: endpoints import the VPC's exports; compute stacks need those endpoints.
all: bootstrap registry network endpoints eks ecs lambda bastion

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
		--parameter-overrides $(COMMON_PARAMS)

ecs:
	$(DEPLOY) --stack-name $(STACK_PREFIX)-ecs \
		--template-file $(INFRA)/30-ecs/cluster.yaml \
		--parameter-overrides $(COMMON_PARAMS)

ecs-weather:
	$(DEPLOY) --stack-name $(STACK_PREFIX)-ecs-weather \
		--template-file $(INFRA)/31-ecs/weather-service.yaml \
		--parameter-overrides $(COMMON_PARAMS) ImageTag=$(shell cat app/weather/.version)

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

# The bastion has no internet route, so charts travel via the artifacts bucket.
charts-stage: charts-version
	aws s3 sync $(CHART_DIR) s3://$(ARTIFACTS_BUCKET)/charts \
		--region $(AWS_REGION) --delete
	@echo "Staged charts to s3://$(ARTIFACTS_BUCKET)/charts"

# Installs the chart from the bastion, because the EKS API is private. SSM Run
# Command is the non-interactive counterpart to "make connect".
app-deploy: app-push charts-stage
	@test -n "$(BASTION_ID)" || { echo "No bastion found. Run 'make bastion'."; exit 1; }
	@echo "Deploying $(RELEASE) to namespace $(NAMESPACE) via $(BASTION_ID)"
	@cid=$$(aws ssm send-command --region $(AWS_REGION) \
		--instance-ids $(BASTION_ID) \
		--document-name AWS-RunShellScript \
		--comment "helm deploy $(RELEASE)" \
		--parameters 'commands=["aws s3 cp s3://$(ARTIFACTS_BUCKET)/charts/bastion-deploy.sh /tmp/bastion-deploy.sh --region $(AWS_REGION)","BUCKET=$(ARTIFACTS_BUCKET) CLUSTER=$(STACK_PREFIX) REGION=$(AWS_REGION) RELEASE=$(RELEASE) NAMESPACE=$(NAMESPACE) bash /tmp/bastion-deploy.sh"]' \
		--query Command.CommandId --output text) && \
	test -n "$$cid" || { echo "send-command returned no command id" >&2; exit 1; }; \
	echo "SSM command $$cid"; \
	aws ssm wait command-executed --region $(AWS_REGION) \
		--command-id $$cid --instance-id $(BASTION_ID) >/dev/null 2>&1 || true; \
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

NODE_IP = $(shell aws ec2 describe-instances --region $(AWS_REGION) \
	--filters 'Name=tag:eks:cluster-name,Values=$(STACK_PREFIX)' \
		'Name=instance-state-name,Values=running' \
	--query 'Reservations[0].Instances[0].PrivateIpAddress' --output text 2>/dev/null)

# Opens http://localhost:$(LOCAL_PORT) on your PC by tunnelling through the
# bastion to a node's NodePort. Runs in the foreground; Ctrl-C to stop.
app-forward:
	@test -n "$(BASTION_ID)" || (echo "No bastion found. Run 'make bastion'." && exit 1)
	@test "$(NODE_IP)" != "None" -a -n "$(NODE_IP)" || (echo "No running EKS nodes found." && exit 1)
	@echo "Forwarding localhost:$(LOCAL_PORT) -> $(NODE_IP):$(NODE_PORT) via $(BASTION_ID)"
	aws ssm start-session --region $(AWS_REGION) --target $(BASTION_ID) \
		--document-name AWS-StartPortForwardingSessionToRemoteHost \
		--parameters host="$(NODE_IP)",portNumber="$(NODE_PORT)",localPortNumber="$(LOCAL_PORT)"

# Internet-facing ALB on port 80, locked to CLIENT_CIDR (defaults to this PC).
# Nodes are registered by attaching the EKS node-group ASG to the target group.
alb:
	@cidr="$(CLIENT_CIDR)"; \
	if [ -z "$$cidr" ]; then \
		ip=$$(curl -sS https://checkip.amazonaws.com | tr -d '[:space:]'); \
		test -n "$$ip" || { echo "Could not detect public IP. Pass CLIENT_CIDR=x.x.x.x/32"; exit 1; }; \
		cidr="$$ip/32"; \
	fi; \
	echo "Deploying ALB allowed from $$cidr"; \
	$(DEPLOY) --stack-name $(STACK_PREFIX)-alb \
		--template-file $(INFRA)/60-alb/alb.yaml \
		--parameter-overrides $(COMMON_PARAMS) AllowedCidr=$$cidr NodePort=$(NODE_PORT)
	@tg=$$(aws cloudformation describe-stacks --region $(AWS_REGION) \
		--stack-name $(STACK_PREFIX)-alb \
		--query 'Stacks[0].Outputs[?OutputKey==`AppTargetGroupArn`].OutputValue' --output text) && \
	asg=$$(aws autoscaling describe-auto-scaling-groups --region $(AWS_REGION) \
		--query "AutoScalingGroups[?Tags[?Key=='eks:cluster-name' && Value=='$(STACK_PREFIX)']].AutoScalingGroupName" \
		--output text) && \
	test -n "$$asg" -a "$$asg" != "None" || { echo "No EKS node Auto Scaling group found."; exit 1; }; \
	echo "Attaching ASG $$asg to target group"; \
	aws autoscaling attach-load-balancer-target-groups --region $(AWS_REGION) \
		--auto-scaling-group-name $$asg --target-group-arns $$tg 2>/dev/null || true
	@aws cloudformation describe-stacks --region $(AWS_REGION) \
		--stack-name $(STACK_PREFIX)-alb \
		--query 'Stacks[0].Outputs[?OutputKey==`AlbUrl`].OutputValue' --output text

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
		$(INFRA)/50-bastion/*.yaml $(INFRA)/60-alb/*.yaml

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

# Endpoints must go before the VPC: the VPC's exports are in use until they do.
destroy-network: destroy-alb destroy-bastion destroy-eks destroy-ecs destroy-lambda destroy-nat
	aws cloudformation delete-stack --region $(AWS_REGION) --stack-name $(STACK_PREFIX)-endpoints
	aws cloudformation wait stack-delete-complete --region $(AWS_REGION) --stack-name $(STACK_PREFIX)-endpoints
	aws cloudformation delete-stack --region $(AWS_REGION) --stack-name $(STACK_PREFIX)-vpc
