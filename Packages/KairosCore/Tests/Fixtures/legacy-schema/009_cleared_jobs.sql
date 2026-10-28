-- 009: jobs you cleared with "Delete all jobs" (2026-10-22). A cleared job is a tombstone like any
-- other (it syncs as deleted), but it isn't "known": a fetch that finds the posting again brings it
-- back as new. Retention's tombstones keep cleared = 0 and stay known, so old postings never return.

ALTER TABLE job ADD COLUMN cleared INTEGER NOT NULL DEFAULT 0 CHECK (cleared IN (0, 1));
