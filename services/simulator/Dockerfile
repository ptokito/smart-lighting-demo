# -----------------------------------------------------------------------------
# simulator container image (no agent: it plays the outside world)
# -----------------------------------------------------------------------------
FROM python:3.12-slim
WORKDIR /app
RUN pip install --no-cache-dir requests
COPY sim.py ./
# -u: unbuffered output so log lines reach kubectl logs and CloudWatch promptly.
CMD ["python", "-u", "sim.py"]
