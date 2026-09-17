-- Recorded before every measured step, so the report can show that the reset
-- actually held and no step faced a bigger table than the one before it.
SELECT json_build_object(
         'liveRows',   (SELECT count(*) FROM events),
         'tableBytes', pg_table_size('events'),
         'indexBytes', pg_indexes_size('events'),
         'totalBytes', pg_total_relation_size('events'))::text;
