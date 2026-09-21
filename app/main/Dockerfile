# Node rather than a plain nginx image: the app has a backend that calls the
# ECS weather service, Lambda agent, AgentCore, and SQS, which are only
# reachable inside the VPC.
FROM node:20-alpine

WORKDIR /app
COPY package.json ./
RUN npm install --omit=dev
COPY server.js ./
COPY web/ ./web/
USER node
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s \
  CMD wget -qO- http://127.0.0.1:8080/healthz || exit 1

CMD ["node", "server.js"]
