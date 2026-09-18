-- The one table both languages write to and read from.
--
-- Loaded once into a template database; every measurement block starts from a
-- copy of it (CREATE DATABASE ... TEMPLATE), so the write scenario of one block
-- never leaves a bigger table or a bloated index for the next. The copy is an
-- exact copy of the contents, not a filesystem-level byte copy: the default
-- WAL_LOG strategy copies block by block through the write-ahead log.
--
-- One million rows: large enough that the primary-key index does not fit in a
-- CPU cache, small enough to sit entirely in shared_buffers after pg_prewarm,
-- so the read scenario measures the services and not the disk.

CREATE EXTENSION IF NOT EXISTS pg_prewarm;

CREATE TABLE events (
    id         bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    subject    text        NOT NULL,
    kind       text        NOT NULL,
    payload    jsonb       NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO events (subject, kind, payload, created_at)
SELECT 'client-bench',
       (ARRAY['page_view', 'click', 'signup', 'purchase'])[1 + g % 4],
       jsonb_build_object('path', '/p/' || (g % 1000), 'ms', g % 500, 'ref', md5(g::text)),
       timestamptz '2026-09-01 00:00:00+00' + make_interval(secs => g)
FROM generate_series(1, 1000000) AS g;

VACUUM (ANALYZE) events;
