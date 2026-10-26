-- =============================================================================
-- Seed data for the Larkspur Ridge Smart Lighting demo
-- -----------------------------------------------------------------------------
-- Creates the four districts, 60 devices, and about 15.5 million historical
-- readings (90 days of check-ins). The large readings table is deliberate:
-- with the index in place the history query takes milliseconds, and without it
-- PostgreSQL has to scan every row, which is the "slow query" demo.
--
-- The history query only looks at the last 7 days, so with the index it
-- reads about 20,000 rows no matter how big the table is. Without the index it
-- reads all of them, so 90 days of history makes the difference dramatic.
--
-- The readings insert takes roughly 2 to 4 minutes on a t3.medium. It only
-- runs when the table is empty, so re-running this file is cheap.
-- =============================================================================

-- Four districts, each with its own crew.
INSERT INTO districts (code, name, crew) VALUES
    ('RV', 'Riverside',         'Crew 1 (Riverside)'),
    ('OM', 'Old Mill',          'Crew 2 (Old Mill)'),
    ('CS', 'Courthouse Square', 'Crew 3 (Courthouse Square)'),
    ('CH', 'Cedar Hollow',      'Crew 4 (Cedar Hollow)')
ON CONFLICT (code) DO NOTHING;

-- 12 streetlights per district (48 total). The street name is picked from a
-- short list so the UI has something readable to show.
INSERT INTO devices (id, kind, district, street)
SELECT
    format('SL-%s-%s', d.code, lpad(n::text, 3, '0')),
    'streetlight',
    d.code,
    (ARRAY['Magnolia Ave', 'Ferry St', 'Hickory Ln', 'Depot Rd'])[1 + (n % 4)]
FROM districts d
CROSS JOIN generate_series(1, 12) AS n
ON CONFLICT (id) DO NOTHING;

-- 3 traffic signals per district (12 total), at intersections.
INSERT INTO devices (id, kind, district, street)
SELECT
    format('TS-%s-%s', d.code, lpad(n::text, 3, '0')),
    'signal',
    d.code,
    (ARRAY['Main St & 1st Ave', 'Main St & Mill Rd', 'Bluff Rd & Court St'])[n]
FROM districts d
CROSS JOIN generate_series(1, 3) AS n
ON CONFLICT (id) DO NOTHING;

-- Historical readings: one row per device every 30 seconds for 90 days is
-- about 15.5 million rows (about 1 GB of table data plus 1 GB of indexes). Only inserted if the table is empty.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM readings LIMIT 1) THEN
        INSERT INTO readings (device_id, ts, power_w, lamp_ok)
        SELECT
            dev.id,
            g.ts,
            -- Streetlights draw about 45 to 60 W; signals about 90 to 120 W.
            CASE WHEN dev.kind = 'streetlight'
                 THEN round((45 + random() * 15)::numeric, 1)
                 ELSE round((90 + random() * 30)::numeric, 1) END,
            -- Roughly 1 in 500 historical readings shows a lamp fault.
            random() > 0.002
        FROM devices dev
        CROSS JOIN generate_series(now() - interval '90 days', now(), interval '30 seconds') AS g(ts);
        ANALYZE readings;
    END IF;
END $$;
