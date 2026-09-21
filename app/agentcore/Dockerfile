# AgentCore Runtime requires linux/arm64. Built with
# `docker buildx build --platform linux/arm64` from the Makefile.
FROM python:3.12-slim

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY agent.py .
COPY skills/ ./skills/

RUN useradd -m -u 1000 bedrock_agentcore
USER bedrock_agentcore

ENV PYTHONUNBUFFERED=1
EXPOSE 8080

CMD ["python", "agent.py"]
