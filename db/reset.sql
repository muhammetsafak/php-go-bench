-- Between two ladder steps: put the table back where the step found it.
--
-- The seed is rows 1..1,000,000 and the read half of the mix only ever asks
-- for ids in that range; everything above is what the write half of the
-- previous step added. Deleting it and vacuuming keeps every step facing the
-- same table size, the same index depth and the same share of shared_buffers.
-- The identity sequence is deliberately not reset: the next step writes fresh
-- ids, as a running service would.
DELETE FROM events WHERE id > 1000000;
VACUUM (ANALYZE) events;
CHECKPOINT;
