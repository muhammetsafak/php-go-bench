-- The write half of the mix with HTTP, JSON parsing and the token taken away:
-- the same row, the same table, the same durability setting, straight into
-- PostgreSQL. What comes out is the database's own ceiling, and therefore the
-- rate above which a comparison between the three runtimes says nothing about
-- the runtimes.
INSERT INTO events (subject, kind, payload)
VALUES ('client-bench', 'page_view',
        '{"path":"/pricing","ms":182,"ref":"newsletter"}')
RETURNING id;
