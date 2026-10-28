-- 011: every place a job is posted, and its life (job collection v2, 2026-10-23;
-- docs/design/job-collection.md). A job is the real opening; a listing is one source's copy of
-- it: the company's board, an Adzuna advert. A job keeps every listing it's found under, knows
-- when each was first and last seen, and closes when its listings stop appearing.

CREATE TABLE listing (
    id               TEXT PRIMARY KEY,                     -- first 16 bytes of SHA-256(canonical_url), hex
    job_id           TEXT NOT NULL,
    source_id        TEXT NOT NULL,
    url              TEXT NOT NULL,
    canonical_url    TEXT NOT NULL,
    title            TEXT NOT NULL,
    company          TEXT NOT NULL,
    location         TEXT NOT NULL DEFAULT '',
    posted_at        INTEGER,
    description      TEXT,                                 -- Markdown; stays on this Mac (the job's copy syncs)
    description_kind TEXT NOT NULL DEFAULT 'full',         -- full, snippet, none
    content_hash     TEXT,                                 -- title, place and text: a change is an edit
    first_seen_at    INTEGER NOT NULL,
    last_seen_at     INTEGER NOT NULL,
    missing_runs     INTEGER NOT NULL DEFAULT 0,           -- complete answers in a row without it
    closed_at        INTEGER,
    updated_hlc      TEXT NOT NULL,
    deleted          INTEGER NOT NULL DEFAULT 0 CHECK (deleted IN (0, 1))
) STRICT;

CREATE INDEX listing_job ON listing (job_id);
CREATE INDEX listing_source ON listing (source_id) WHERE deleted = 0;

-- What happened to a job, for "where did this come from, and is it still up?".
CREATE TABLE job_event (
    id          TEXT PRIMARY KEY,                          -- UUIDv7
    job_id      TEXT NOT NULL,
    at          INTEGER NOT NULL,
    kind        TEXT NOT NULL,                             -- found, posted_elsewhere, changed, upgraded, closed, reopened
    source_id   TEXT,
    detail      TEXT,
    updated_hlc TEXT NOT NULL,
    deleted     INTEGER NOT NULL DEFAULT 0 CHECK (deleted IN (0, 1))
) STRICT;

CREATE INDEX job_event_job ON job_event (job_id, at);

ALTER TABLE job ADD COLUMN last_seen_at INTEGER;
ALTER TABLE job ADD COLUMN closed_at INTEGER;
ALTER TABLE job ADD COLUMN description_kind TEXT NOT NULL DEFAULT 'full';
ALTER TABLE job ADD COLUMN primary_listing_id TEXT;

-- How each source answered last time on this Mac: what to send for "only if it changed". Local.
CREATE TABLE source_fetch_state (
    source_id   TEXT PRIMARY KEY,
    etag        TEXT,
    fingerprint TEXT,                                      -- the settings the etag was taken under
    last_ok_at  INTEGER,
    fail_runs   INTEGER NOT NULL DEFAULT 0
) STRICT;

-- Every request a fetch made, for coverage, budgets and debugging. Local, kept 30 days.
CREATE TABLE fetch_log (
    id           INTEGER PRIMARY KEY,
    run_id       TEXT,
    source_id    TEXT NOT NULL,
    at           INTEGER NOT NULL,
    request      TEXT NOT NULL,                            -- "board", or a search and its page
    outcome      TEXT NOT NULL,                            -- ok, unchanged, failed
    http_status  INTEGER,
    error        TEXT,
    items        INTEGER NOT NULL DEFAULT 0,
    added        INTEGER NOT NULL DEFAULT 0,
    changed      INTEGER NOT NULL DEFAULT 0,
    closed       INTEGER NOT NULL DEFAULT 0,
    ms           INTEGER NOT NULL DEFAULT 0
) STRICT;

CREATE INDEX fetch_log_at ON fetch_log (at);
CREATE INDEX fetch_log_source ON fetch_log (source_id, at);

-- Every job so far becomes its own first listing; Adzuna's are snippets.
INSERT INTO listing (id, job_id, source_id, url, canonical_url, title, company, location, posted_at, description,
    description_kind, first_seen_at, last_seen_at, updated_hlc, deleted)
SELECT job.id, job.id, job.source_id, job.url, job.canonical_url, job.title, job.company, job.location, job.posted_at,
    job.description,
    CASE
        WHEN job.description IS NULL THEN 'none'
        WHEN job.source_id IN (SELECT id FROM source WHERE kind = 'adzuna') THEN 'snippet'
        ELSE 'full'
    END,
    job.first_seen_at, job.first_seen_at, job.updated_hlc, job.deleted
FROM job;

UPDATE job SET last_seen_at = first_seen_at, primary_listing_id = id,
    description_kind = CASE
        WHEN description IS NULL THEN 'none'
        WHEN source_id IN (SELECT id FROM source WHERE kind = 'adzuna') THEN 'snippet'
        ELSE 'full'
    END;
