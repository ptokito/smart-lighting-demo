"""
device-gateway: the field network gateway for Larkspur Ridge Smart Lighting.

Where it runs
    On the host VM (lighting-host) as a systemd service, NOT in Kubernetes.
    This is deliberate: the assignment gives bonus points for a customer-like
    environment with applications on both virtual hosts and Kubernetes, and a
    real city would run its field gateway on a dedicated server.

What it does
    1. Receives check-ins (heartbeats) from every streetlight and traffic
       signal: power draw and lamp health. Each check-in is stored in
       PostgreSQL and recorded as a New Relic custom event (LightingCheckIn).
    2. Relays operator commands ("turn on", "dim to 50%", "flash mode") to a
       device and waits for the device to acknowledge. The time that takes is
       the business number this whole demo is about: a light that takes too
       long to respond. Each command is recorded as a custom event
       (LightCommand) with ackMs, the acknowledgement time in milliseconds.

How it is instrumented
    The New Relic Python APM agent wraps the process from the outside
    (newrelic-admin run-program, see the systemd unit), so there is no agent
    setup code here beyond the custom events and attributes below. The agent
    automatically times every request, every PostgreSQL query and every Redis
    call, and links this service into distributed traces that start in the
    browser and pass through the Kubernetes services.

Demo fault: gateway lag
    If the Redis key fault:gateway-lag holds a district code (RV, OM, CS, CH)
    or "ALL", commands to devices in that district take 4 to 8 seconds to
    acknowledge instead of 150 to 600 ms. Every service stays up and returns
    200 OK, so only latency, the SLO and the business alert reveal it.
"""

import logging
import os
import random
import time

import newrelic.agent          # used only for custom events and attributes
import psycopg2
import psycopg2.pool
import redis
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

# -----------------------------------------------------------------------------
# Logging: plain lines to stdout. systemd appends stdout to
# /var/log/smart-lighting/device-gateway.log, where the CloudWatch agent picks
# it up for the S3 archive. The New Relic agent also forwards these log lines
# to New Relic and stamps them with the trace ID ("logs in context").
# -----------------------------------------------------------------------------
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s device-gateway %(message)s",
)
log = logging.getLogger("device-gateway")

# -----------------------------------------------------------------------------
# Configuration comes from environment variables set in
# /etc/smart-lighting/device-gateway.env (written by the bootstrap script from
# AWS Systems Manager Parameter Store, so no secret lives in this repo).
# -----------------------------------------------------------------------------
DB_DSN = (
    f"host={os.environ.get('DB_HOST', '127.0.0.1')} "
    f"dbname=lighting user=lighting password={os.environ['DB_PASSWORD']}"
)
REDIS_HOST = os.environ.get("REDIS_HOST", "127.0.0.1")
REDIS_PASSWORD = os.environ["REDIS_PASSWORD"]

# A small connection pool so concurrent requests do not each open a new
# PostgreSQL connection (which would show up as slow "connect" spans).
pool = psycopg2.pool.ThreadedConnectionPool(minconn=1, maxconn=10, dsn=DB_DSN)
cache = redis.Redis(host=REDIS_HOST, password=REDIS_PASSWORD, decode_responses=True)

# Device ID format is <TYPE>-<DISTRICT>-<NUMBER>, e.g. SL-RV-007. Parsing it
# here avoids a database lookup on every request.
KIND_BY_PREFIX = {"SL": "streetlight", "TS": "signal"}

app = FastAPI(title="Larkspur Ridge device gateway")


class CheckIn(BaseModel):
    """A heartbeat sent by a device every 30 seconds."""
    device_id: str
    power_w: float
    lamp_ok: bool


class Command(BaseModel):
    """A command relayed from lighting-api to a device."""
    device_id: str
    command: str
    source: str = "operator"


def parse_device(device_id: str):
    """Split a device ID into (kind, district). Raises 400 on a bad ID."""
    parts = device_id.split("-")
    if len(parts) != 3 or parts[0] not in KIND_BY_PREFIX:
        raise HTTPException(status_code=400, detail=f"Malformed device id {device_id}")
    return KIND_BY_PREFIX[parts[0]], parts[1]


def field_network_delay_ms(district: str) -> int:
    """
    How long the simulated field network takes to acknowledge a command.

    Normal: 150 to 600 ms. During the gateway-lag fault, devices in the
    affected district take 4,000 to 8,000 ms. The fault is read from Redis on
    every call so it can be switched on and off without restarting anything.
    """
    lagging = cache.get("fault:gateway-lag")
    if lagging and lagging.upper() in (district, "ALL"):
        return random.randint(4000, 8000)
    return random.randint(150, 600)


@app.get("/healthz")
def healthz():
    """Liveness check used by systemd, the bootstrap script and smoke tests."""
    return {"status": "ok"}


@app.post("/checkin")
def checkin(body: CheckIn):
    """Store a device heartbeat and record it as a New Relic custom event."""
    kind, district = parse_device(body.device_id)

    conn = pool.getconn()
    try:
        with conn, conn.cursor() as cur:
            cur.execute(
                "INSERT INTO readings (device_id, power_w, lamp_ok) VALUES (%s, %s, %s)",
                (body.device_id, body.power_w, body.lamp_ok),
            )
            cur.execute(
                "UPDATE devices SET last_seen = now(), last_lamp_ok = %s, last_power_w = %s WHERE id = %s",
                (body.lamp_ok, body.power_w, body.device_id),
            )
    finally:
        pool.putconn(conn)

    # Custom event: one row per heartbeat in New Relic's LightingCheckIn table.
    # The dashboard and the "devices not checking in" alert query this.
    newrelic.agent.record_custom_event("LightingCheckIn", {
        "deviceId": body.device_id,
        "kind": kind,
        "district": district,
        "powerW": body.power_w,
        "lampOk": body.lamp_ok,
    })

    if not body.lamp_ok:
        # Warning-level log line; shows up in New Relic Logs linked to this trace.
        log.warning("lamp fault reported device=%s district=%s", body.device_id, district)
    return {"stored": True}


@app.post("/commands")
def relay_command(body: Command):
    """
    Relay a command to a device and wait for the acknowledgement.

    The sleep stands in for the round trip over the city's field radio network.
    Because the APM agent times this whole request, a slow acknowledgement
    shows up directly as higher response time on this service, and as a long
    span inside every distributed trace that issued the command.
    """
    kind, district = parse_device(body.device_id)

    # Attributes attached to this transaction and its trace, so in New Relic you
    # can filter or facet slow requests by district, device or command.
    newrelic.agent.add_custom_attributes([
        ("deviceId", body.device_id),
        ("district", district),
        ("deviceKind", kind),
        ("command", body.command),
    ])

    started = time.monotonic()
    time.sleep(field_network_delay_ms(district) / 1000.0)   # simulated radio round trip
    ack_ms = int((time.monotonic() - started) * 1000)

    conn = pool.getconn()
    try:
        with conn, conn.cursor() as cur:
            cur.execute(
                "INSERT INTO commands (device_id, command, ack_ms, source) VALUES (%s, %s, %s, %s)",
                (body.device_id, body.command, ack_ms, body.source),
            )
    finally:
        pool.putconn(conn)

    # The business-level event behind the SLO "light commands acknowledged
    # within 2 seconds" and the alert "light commands slow to acknowledge".
    newrelic.agent.record_custom_event("LightCommand", {
        "deviceId": body.device_id,
        "kind": kind,
        "district": district,
        "command": body.command,
        "source": body.source,
        "ackMs": ack_ms,
        "onTime": ack_ms <= 2000,
    })
    newrelic.agent.add_custom_attribute("ackMs", ack_ms)

    if ack_ms > 2000:
        log.warning("slow acknowledgement device=%s district=%s ack_ms=%d", body.device_id, district, ack_ms)
    else:
        log.info("command acknowledged device=%s command=%s ack_ms=%d", body.device_id, body.command, ack_ms)
    return {"device_id": body.device_id, "command": body.command, "ack_ms": ack_ms}
