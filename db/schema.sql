-- =============================================================================
-- City of Larkspur Ridge Smart Lighting program: database schema
-- -----------------------------------------------------------------------------
-- Runs once on the host VM (lighting-host) during bootstrap, as the PostgreSQL
-- superuser, against the "lighting" database. Every statement is written so the
-- file can be re-run safely (IF NOT EXISTS / ON CONFLICT), which matters when a
-- bootstrap step is retried.
--
-- Tables:
--   districts    the four city districts used to group devices and crews
--   devices      48 LED streetlights and 12 traffic signals
--   readings     device check-ins (power draw, lamp health); millions of rows
--                so a missing index produces a genuinely slow query
--   commands     every command an operator or schedule sent, with how long the
--                field network took to acknowledge it
--   work_orders  repair jobs created by the crew-dispatch service
-- =============================================================================

CREATE TABLE IF NOT EXISTS districts (
    code        TEXT PRIMARY KEY,          -- short code used in device IDs, e.g. RV
    name        TEXT NOT NULL,             -- display name, e.g. Riverside
    crew        TEXT NOT NULL              -- maintenance crew that covers the district
);

CREATE TABLE IF NOT EXISTS devices (
    id            TEXT PRIMARY KEY,        -- e.g. SL-RV-007 (streetlight) or TS-RV-002 (signal)
    kind          TEXT NOT NULL CHECK (kind IN ('streetlight', 'signal')),
    district      TEXT NOT NULL REFERENCES districts(code),
    street        TEXT NOT NULL,           -- fictional street the device sits on
    firmware      TEXT NOT NULL DEFAULT '3.2.1',
    -- The gateway updates the next three columns on every check-in, so the API
    -- can show current status with one cheap query instead of scanning readings.
    last_seen     TIMESTAMPTZ,
    last_lamp_ok  BOOLEAN,
    last_power_w  NUMERIC(6,1)
);

CREATE TABLE IF NOT EXISTS readings (
    id          BIGSERIAL PRIMARY KEY,
    device_id   TEXT NOT NULL REFERENCES devices(id),
    ts          TIMESTAMPTZ NOT NULL DEFAULT now(),
    power_w     NUMERIC(6,1) NOT NULL,     -- power draw in watts
    lamp_ok     BOOLEAN NOT NULL           -- false when the device reports a lamp fault
);

-- This index is what keeps the device-history query fast. The "slow-query"
-- demo fault drops it on purpose and recreates it afterwards.
CREATE INDEX IF NOT EXISTS idx_readings_device_ts ON readings (device_id, ts DESC);

CREATE TABLE IF NOT EXISTS commands (
    id          BIGSERIAL PRIMARY KEY,
    device_id   TEXT NOT NULL REFERENCES devices(id),
    command     TEXT NOT NULL,             -- on, off, dim:50, flash, normal
    issued_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    ack_ms      INTEGER NOT NULL,          -- how long the field network took to acknowledge
    source      TEXT NOT NULL DEFAULT 'operator'
);
CREATE INDEX IF NOT EXISTS idx_commands_issued ON commands (issued_at DESC);

CREATE TABLE IF NOT EXISTS work_orders (
    id           BIGSERIAL PRIMARY KEY,
    device_id    TEXT NOT NULL REFERENCES devices(id),
    district     TEXT NOT NULL REFERENCES districts(code),
    description  TEXT NOT NULL,
    source       TEXT NOT NULL,            -- resident, operator or synthetic
    crew         TEXT NOT NULL,
    priority     TEXT NOT NULL,            -- high for signals, normal for streetlights
    status       TEXT NOT NULL DEFAULT 'assigned',
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
