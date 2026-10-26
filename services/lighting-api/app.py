"""
lighting-api: the backend for the Larkspur Ridge Smart Lighting portal.

Where it runs
    In Kubernetes (k3s) on the lighting-k3s EC2 instance, 2 replicas.

What it does
    GET  /api/summary                 city-wide counts per district (cached)
    GET  /api/devices                 every device with its current status
    GET  /api/devices/{id}/history    hourly power and fault history (7 days)
    POST /api/commands                send a command to a device via device-gateway
    POST /api/reports                 a resident reports a light out; creates a
                                      work order via crew-dispatch

How it is instrumented
    New Relic Python APM agent, started from outside by newrelic-admin in the
    Dockerfile. The agent traces every request, every SQL statement (with the
    statement text obfuscated, see the Kubernetes manifest), every Redis call
    and every outgoing HTTP call, and propagates W3C trace context so the trace
    continues into device-gateway (New Relic agent) and crew-dispatch
    (OpenTelemetry). Custom attributes added below make traces searchable by
    device and district.

Demo faults this service takes part in
    * Slow query:     /api/devices/{id}/history runs a range query on the
                      5-million-row readings table. If the index is dropped,
                      the query becomes a full table scan.
    * Timeout:        /api/reports calls crew-dispatch with a 3 second timeout.
                      If crew-dispatch hangs, this service records a timeout
                      error and returns 504.
    * Bad release:    release.json controls the status cache. Version 1.1.0
                      in the demo turns it off, and /api/devices falls back to
                      one query per device (the classic "N+1" problem).
"""

import json
import logging
import os
from pathlib import Path

import newrelic.agent
import psycopg2
import psycopg2.extras
import psycopg2.pool
import redis
import requests
from fastapi import FastAPI, HTTPException
from fastapi.responses import JSONResponse
from pydantic import BaseModel

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s lighting-api %(message)s")
log = logging.getLogger("lighting-api")

# -----------------------------------------------------------------------------
# Release settings, baked into the container image. Changing this file and
# pushing to GitHub is how the "bad release" demo works: GitHub Actions builds
# and deploys the new image and records a change marker in New Relic.
# -----------------------------------------------------------------------------
RELEASE = json.loads((Path(__file__).parent / "release.json").read_text())
RELEASE_VERSION = RELEASE["version"]
STATUS_CACHE_ENABLED = RELEASE["statusCache"]

# -----------------------------------------------------------------------------
# Connections. Values come from the Kubernetes ConfigMap and Secret, which the
# bootstrap script fills from AWS Systems Manager Parameter Store.
# DB_HOST and REDIS_HOST are the host VM's private IP address.
# -----------------------------------------------------------------------------
DB_DSN = (
    f"host={os.environ['DB_HOST']} dbname=lighting user=lighting "
    f"password={os.environ['DB_PASSWORD']} connect_timeout=5"
)
pool = psycopg2.pool.ThreadedConnectionPool(minconn=1, maxconn=10, dsn=DB_DSN)
cache = redis.Redis(host=os.environ["REDIS_HOST"], password=os.environ["REDIS_PASSWORD"],
                    decode_responses=True, socket_timeout=2)

GATEWAY_URL = os.environ["GATEWAY_URL"]          # http://<host VM IP>:8081
DISPATCH_URL = os.environ["DISPATCH_URL"]        # http://crew-dispatch:8082 (in-cluster)
DISPATCH_TIMEOUT_S = 3                           # give up on crew-dispatch after 3 seconds
GATEWAY_TIMEOUT_S = 10                           # field network can be slow; do not cut it off

app = FastAPI(title="Larkspur Ridge lighting API")


class CommandIn(BaseModel):
    device_id: str
    command: str
    source: str = "operator"


class ReportIn(BaseModel):
    device_id: str
    description: str
    source: str = "resident"


def query(sql, params=None):
    """Run a read query and return rows as dictionaries."""
    conn = pool.getconn()
    try:
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute(sql, params)
            return cur.fetchall()
    finally:
        pool.putconn(conn)


def tag_release():
    """Every transaction carries the release version, so you can facet by it."""
    newrelic.agent.add_custom_attributes([
        ("releaseVersion", RELEASE_VERSION),
        ("statusCacheEnabled", STATUS_CACHE_ENABLED),
    ])


@app.get("/healthz")
def healthz():
    return {"status": "ok", "release": RELEASE_VERSION}


@app.get("/api/summary")
def summary():
    """Per-district counts for the dashboard header. Cached for 15 seconds."""
    tag_release()
    cached = cache.get("cache:summary") if STATUS_CACHE_ENABLED else None
    if cached:
        newrelic.agent.add_custom_attribute("cacheHit", True)
        return json.loads(cached)

    newrelic.agent.add_custom_attribute("cacheHit", False)
    rows = query("""
        SELECT d.code, d.name,
               count(v.id)                                            AS devices,
               count(v.id) FILTER (WHERE v.last_lamp_ok IS FALSE)     AS lamp_faults,
               count(v.id) FILTER (WHERE v.last_seen < now() - interval '2 minutes'
                                      OR v.last_seen IS NULL)         AS silent,
               (SELECT count(*) FROM work_orders w
                 WHERE w.district = d.code AND w.status = 'assigned') AS open_work_orders,
               (SELECT round(avg(c.ack_ms)) FROM commands c JOIN devices x ON x.id = c.device_id
                 WHERE x.district = d.code
                   AND c.issued_at > now() - interval '15 minutes')   AS avg_ack_ms
        FROM districts d LEFT JOIN devices v ON v.district = d.code
        GROUP BY d.code, d.name ORDER BY d.name
    """)
    result = {"release": RELEASE_VERSION, "districts": rows}
    if STATUS_CACHE_ENABLED:
        cache.setex("cache:summary", 15, json.dumps(result, default=str))
    return result


@app.get("/api/devices")
def devices():
    """
    Every device with its current status.

    With the status cache on (release 1.0.0) this is one query, cached for 15
    seconds. With it off (the bad release), the code counts recent faults for
    each device in a separate query: 60 devices means 60 extra round trips to
    PostgreSQL per request. In the distributed trace this shows up as a long
    ladder of identical database spans, which is the visual punchline.
    """
    tag_release()
    if STATUS_CACHE_ENABLED:
        cached = cache.get("cache:devices")
        if cached:
            newrelic.agent.add_custom_attribute("cacheHit", True)
            return json.loads(cached)

    newrelic.agent.add_custom_attribute("cacheHit", False)
    rows = query("SELECT id, kind, district, street, firmware, last_seen, last_lamp_ok, last_power_w "
                 "FROM devices ORDER BY id")

    if STATUS_CACHE_ENABLED:
        cache.setex("cache:devices", 15, json.dumps(rows, default=str))
    else:
        # The regression: a "7-day fault count" feature, computed with one
        # query per device (N+1) and no cache. Each query is reasonable on its
        # own (about 20,000 rows through the index); 60 of them on every page
        # load add a second or more.
        for row in rows:
            row["faults_7d"] = query(
                "SELECT count(*) AS n FROM readings WHERE device_id = %s "
                "AND ts > now() - interval '7 days' AND lamp_ok IS FALSE",
                (row["id"],),
            )[0]["n"]
    return rows


@app.get("/api/devices/{device_id}/history")
def device_history(device_id: str):
    """
    Hourly average power and fault count for one device over 7 days.

    With idx_readings_device_ts this reads about 20,000 rows through the index.
    Without it (the slow-query fault), PostgreSQL scans all ~15.5 million rows.
    The APM agent captures it as a slow SQL trace with an explain plan, the
    PostgreSQL log records it (log_min_duration_statement), and both the trace
    and the log line land in New Relic.
    """
    tag_release()
    newrelic.agent.add_custom_attribute("deviceId", device_id)
    rows = query("""
        SELECT date_trunc('hour', ts)                    AS hour,
               round(avg(power_w), 1)                    AS avg_power_w,
               count(*) FILTER (WHERE lamp_ok IS FALSE)  AS faults
        FROM readings
        WHERE device_id = %s AND ts > now() - interval '7 days'
        GROUP BY 1 ORDER BY 1
    """, (device_id,))
    if not rows:
        raise HTTPException(status_code=404, detail="Unknown device")
    return rows


@app.post("/api/commands")
def send_command(body: CommandIn):
    """Send a command to a device through device-gateway on the host VM."""
    tag_release()
    district = body.device_id.split("-")[1] if body.device_id.count("-") == 2 else "unknown"
    newrelic.agent.add_custom_attributes([("deviceId", body.device_id), ("district", district),
                                          ("command", body.command)])
    # requests is auto-instrumented: this call becomes an "external" span and
    # carries the trace context header to device-gateway.
    resp = requests.post(f"{GATEWAY_URL}/commands", json=body.model_dump(), timeout=GATEWAY_TIMEOUT_S)
    if resp.status_code >= 400:
        raise HTTPException(status_code=resp.status_code, detail=resp.text)
    cache.delete("cache:summary")
    return resp.json()


@app.post("/api/reports")
def report_outage(body: ReportIn):
    """
    A resident (or the synthetic monitor) reports a light that is out.
    Validates the device, then asks crew-dispatch to create a work order.
    """
    tag_release()
    rows = query("SELECT id, kind, district FROM devices WHERE id = %s", (body.device_id,))
    if not rows:
        # A 404 is a user mistake, not a service error, so the agent does not
        # count it toward the error rate.
        log.info("report for unknown device=%s", body.device_id)
        raise HTTPException(status_code=404, detail="We could not find that pole number.")
    device = rows[0]
    newrelic.agent.add_custom_attributes([("deviceId", device["id"]), ("district", device["district"]),
                                          ("reportSource", body.source)])
    try:
        resp = requests.post(
            f"{DISPATCH_URL}/dispatch",
            json={"device_id": device["id"], "district": device["district"], "kind": device["kind"],
                  "description": body.description, "source": body.source},
            timeout=DISPATCH_TIMEOUT_S,
        )
        resp.raise_for_status()
    except requests.exceptions.Timeout:
        # Record the timeout as an error on this transaction (it appears in
        # Errors Inbox with its stack trace) and answer 504 Gateway Timeout.
        newrelic.agent.notice_error()
        log.error("crew-dispatch timed out after %ss device=%s", DISPATCH_TIMEOUT_S, device["id"])
        return JSONResponse(status_code=504,
                            content={"detail": "Your report was received but crew assignment is delayed."})
    log.info("work order created device=%s district=%s", device["id"], device["district"])
    return resp.json()
