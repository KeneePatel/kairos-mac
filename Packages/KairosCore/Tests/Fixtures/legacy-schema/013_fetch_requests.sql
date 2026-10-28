-- 013: how many requests each logged fetch took (job collection v2, J4). A search pages, and its
-- plan counts every page: Adzuna's free plan allows 250 a day and 2,500 a month.

ALTER TABLE fetch_log ADD COLUMN requests INTEGER NOT NULL DEFAULT 1;
