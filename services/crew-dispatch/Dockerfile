# -----------------------------------------------------------------------------
# crew-dispatch container image (OpenTelemetry only, no New Relic agent)
# -----------------------------------------------------------------------------
FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
# 1. Install the app and the OpenTelemetry SDK, distro and OTLP exporter.
# 2. opentelemetry-bootstrap looks at the installed libraries and installs the
#    matching auto-instrumentation packages (FastAPI, psycopg2, Redis, logging).
RUN pip install --no-cache-dir -r requirements.txt \
 && opentelemetry-bootstrap -a install

COPY app.py ./

EXPOSE 8082

# opentelemetry-instrument sets up tracing, metrics and logging from the OTEL_*
# environment variables (see k8s/crew-dispatch.yaml), then runs uvicorn.
CMD ["opentelemetry-instrument", "uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8082"]
