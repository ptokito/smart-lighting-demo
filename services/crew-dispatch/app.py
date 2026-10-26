"""
crew-dispatch: assigns a maintenance crew when a light is reported out.

Where it runs
    In Kubernetes (k3s), 1 replica.

Why it is different from the other services
    This service has NO New Relic agent. It is instrumented only with
    OpenTelemetry (OTel), the vendor-neutral open standard, and sends traces,
    metrics and logs straight to New Relic's OTLP endpoint. The assignment asks
    to "use both APM agents and collect OpenTelemetry data", and this shows the
    two working side by side: lighting-api (New Relic agent) calls this service
    (OTel), and the distributed trace stays connected because both use the
    same W3C trace context standard.

How the instrumentation is wired
    * Automatic: the Dockerfile starts the app with `opentelemetry-instrument`,
      which instruments FastAPI, psycopg2 (PostgreSQL) and Redis without code
      changes. Exporter settings are OTEL_* environment variables in
      k8s/crew-dispatch.yaml.
    * Manual (the bonus): a custom span named "assign_crew" with business
      attributes, and a custom counter metric "lighting.work_orders.created".

Demo fault: dispatch timeout
    If the Redis key fault:dispatch-timeout is "on", this service sleeps for
    8 seconds before answering. lighting-api gives up after 3 seconds, so the
    resident sees a delay and New Relic records timeout errors.
"""

import logging
import os
import time

import psycopg2
import psycopg2.pool
import redis
from fastapi import FastAPI
from opentelemetry import metrics, trace
from pydantic import BaseModel

# The OTel logging instrumentation (enabled in the manifest) attaches trace and
# span IDs to these records and exports them, so logs link to traces in New Relic.
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s crew-dispatch %(message)s")
log = logging.getLogger("crew-dispatch")

# Tracer and meter for the manual instrumentation. The SDK behind them is set up
# by opentelemetry-instrument at startup.
tracer = trace.get_tracer("crew-dispatch")
meter = metrics.get_meter("crew-dispatch")
work_orders_created = meter.create_counter(
    "lighting.work_orders.created",
    unit="1",
    description="Work orders created, by district and priority",
)

DB_DSN = (
    f"host={os.environ['DB_HOST']} dbname=lighting user=lighting "
    f"password={os.environ['DB_PASSWORD']} connect_timeout=5"
)
pool = psycopg2.pool.ThreadedConnectionPool(minconn=1, maxconn=5, dsn=DB_DSN)
cache = redis.Redis(host=os.environ["REDIS_HOST"], password=os.environ["REDIS_PASSWORD"],
                    decode_responses=True, socket_timeout=2)

app = FastAPI(title="Larkspur Ridge crew dispatch")


class DispatchIn(BaseModel):
    device_id: str
    district: str
    kind: str
    description: str
    source: str = "resident"


@app.get("/healthz")
def healthz():
    return {"status": "ok"}


@app.post("/dispatch")
def dispatch(body: DispatchIn):
    """Create a work order and assign the district's crew."""
    # Demo fault: hang long enough for the caller's 3 second timeout to fire.
    if cache.get("fault:dispatch-timeout") == "on":
        log.warning("dispatch fault active, delaying response 8s device=%s", body.device_id)
        time.sleep(8)

    # Custom span wrapping the business step. Attributes become searchable
    # fields on the span in New Relic (e.g. FACET lighting.district).
    with tracer.start_as_current_span("assign_crew") as span:
        priority = "high" if body.kind == "signal" else "normal"   # a dark signal is a safety issue
        span.set_attribute("lighting.device_id", body.device_id)
        span.set_attribute("lighting.district", body.district)
        span.set_attribute("lighting.priority", priority)
        span.set_attribute("lighting.report_source", body.source)

        conn = pool.getconn()
        try:
            with conn, conn.cursor() as cur:
                cur.execute("SELECT crew FROM districts WHERE code = %s", (body.district,))
                crew = cur.fetchone()[0]
                cur.execute(
                    "INSERT INTO work_orders (device_id, district, description, source, crew, priority) "
                    "VALUES (%s, %s, %s, %s, %s, %s) RETURNING id",
                    (body.device_id, body.district, body.description[:500], body.source, crew, priority),
                )
                work_order_id = cur.fetchone()[0]
        finally:
            pool.putconn(conn)

        span.set_attribute("lighting.crew", crew)
        span.set_attribute("lighting.work_order_id", work_order_id)

    work_orders_created.add(1, {"district": body.district, "priority": priority})
    log.info("work order %s assigned to %s device=%s priority=%s", work_order_id, crew, body.device_id, priority)
    return {"work_order_id": work_order_id, "crew": crew, "priority": priority}
