-- 001: job sources, saved searches, postings and run history (SPEC §6.2).
--
-- All four tables sync, so each carries updated_hlc and deleted and has no FOREIGN KEY (SPEC §6.1).
-- Enum-like columns have no CHECK list: a CHECK can't change without rebuilding the table, and the
-- Swift types are where the allowed values live. Times are INTEGER milliseconds since 1970, UTC.

CREATE TABLE source (
    id          TEXT PRIMARY KEY,                              -- UUIDv7
    kind        TEXT NOT NULL,                                 -- greenhouse, lever, ashby, adzuna, linkedin, ...
    config      TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(config)),
    enabled     INTEGER NOT NULL DEFAULT 1 CHECK (enabled IN (0, 1)),
    last_run_at INTEGER,
    health      TEXT NOT NULL DEFAULT 'ok',                    -- ok, degraded
    empty_runs  INTEGER NOT NULL DEFAULT 0,                    -- runs in a row with no results
    updated_hlc TEXT NOT NULL,
    deleted     INTEGER NOT NULL DEFAULT 0 CHECK (deleted IN (0, 1))
) STRICT;

CREATE TABLE search (
    id            TEXT PRIMARY KEY,                            -- UUIDv7
    terms         TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(terms)),
    location      TEXT NOT NULL DEFAULT '',
    countries     TEXT NOT NULL DEFAULT '["CA","US"]' CHECK (json_valid(countries)),  -- in priority order
    remote        INTEGER NOT NULL DEFAULT 1 CHECK (remote IN (0, 1)),
    max_age_hours INTEGER,                                     -- NULL: no limit
    updated_hlc   TEXT NOT NULL,
    deleted       INTEGER NOT NULL DEFAULT 0 CHECK (deleted IN (0, 1))
) STRICT;

CREATE TABLE job (
    id             TEXT PRIMARY KEY,                           -- first 16 bytes of SHA-256(canonical_url), hex
    source_id      TEXT NOT NULL,
    url            TEXT NOT NULL,
    canonical_url  TEXT NOT NULL,
    dedup_key      TEXT NOT NULL,                              -- company + title + city, normalized
    company        TEXT NOT NULL,
    title          TEXT NOT NULL,
    location       TEXT NOT NULL DEFAULT '',                   -- as posted
    city           TEXT,
    region         TEXT,                                       -- province or state code: ON, BC, NY, ...
    country        TEXT,                                       -- CA or US; NULL until parsed
    remote_scope   TEXT NOT NULL DEFAULT 'unknown',
    currency       TEXT,                                       -- ISO 4217: CAD, USD
    salary         TEXT CHECK (salary IS NULL OR json_valid(salary)),
    posted_at      INTEGER,
    description    TEXT,                                       -- Markdown; NULL in stubs and tombstones
    state          TEXT NOT NULL DEFAULT 'new',
    verdict        TEXT,                                       -- yes, maybe, no; NULL until screened
    verdict_source TEXT,                                       -- prefilter, analysis, user
    rank           REAL,                                       -- higher first; NULL until ranked
    first_seen_at  INTEGER NOT NULL,
    updated_hlc    TEXT NOT NULL,
    deleted        INTEGER NOT NULL DEFAULT 0 CHECK (deleted IN (0, 1))
) STRICT;

CREATE INDEX job_state_verdict ON job (state, verdict) WHERE deleted = 0;
CREATE INDEX job_country ON job (country) WHERE deleted = 0;
CREATE INDEX job_dedup_key ON job (dedup_key);
CREATE INDEX job_source ON job (source_id);

CREATE TABLE run (
    id          TEXT PRIMARY KEY,                              -- UUIDv7
    kind        TEXT NOT NULL,                                 -- fetch, screen, tailor, ...
    started_at  INTEGER NOT NULL,
    finished_at INTEGER,
    stats       TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(stats)),
    error       TEXT,
    updated_hlc TEXT NOT NULL,
    deleted     INTEGER NOT NULL DEFAULT 0 CHECK (deleted IN (0, 1))
) STRICT;

CREATE INDEX run_started ON run (started_at);
