# -----------------------------------------------------------------------------
# lighting-api container image
# Built on the k3s node by scripts/deploy-k3s.sh (no registry needed).
# -----------------------------------------------------------------------------
FROM python:3.12-slim

WORKDIR /app

# Install dependencies first so Docker can cache this layer between builds.
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py release.json ./

EXPOSE 8080

# newrelic-admin run-program starts the New Relic agent, then runs uvicorn
# inside it. All agent settings come from NEW_RELIC_* environment variables
# set in k8s/lighting-api.yaml, so there is no newrelic.ini file.
CMD ["newrelic-admin", "run-program", "uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8080"]
