-- Kairos's local database. One file per Mac, WAL mode, STRICT tables. Times are INTEGER
-- milliseconds since 1970 (UTC); JSON columns are checked with json_valid. Enum-like columns have no
-- CHECK list (a CHECK can't change without rebuilding the table): the Swift types hold the values
-- and an unknown one reads as a damaged row. Child rows go with their parent (ON DELETE CASCADE).

-- Settings: JSON documents owned by the module that reads them ("screening", "llm", ...).
CREATE TABLE setting (
    key        TEXT PRIMARY KEY,
    value      TEXT NOT NULL CHECK (json_valid(value)),
    updated_at INTEGER NOT NULL
) STRICT;

-- Where jobs come from: one row per company board, and one per search.
CREATE TABLE source (
    id             TEXT PRIMARY KEY,                -- UUIDv7
    kind           TEXT NOT NULL,                   -- greenhouse, lever, ..., himalayas, google_jobs, adzuna
    slug           TEXT NOT NULL DEFAULT '',        -- the board's token; '' for a search
    name           TEXT NOT NULL DEFAULT '',        -- the company's name as shown
    region         TEXT,                            -- 'eu' for Lever's EU instance
    origin         TEXT NOT NULL,                   -- you, catalog, link, lead, search
    status         TEXT NOT NULL DEFAULT 'watching',-- watching, muted, gone, removed
    added_at       INTEGER NOT NULL,
    checked_at     INTEGER,                         -- the last read, good or not
    ok_at          INTEGER,                         -- the last good read
    etag           TEXT,                            -- for "only if it changed"
    fail_streak    INTEGER NOT NULL DEFAULT 0,      -- failed reads in a row
    missing_streak INTEGER NOT NULL DEFAULT 0,      -- "not found" in a row: three and it's gone
    quiet_streak   INTEGER NOT NULL DEFAULT 0,      -- good reads in a row with nothing for you
    rest_until     INTEGER,                         -- a quiet catalog board rests until then
    last_error     TEXT,
    UNIQUE (kind, slug)
) STRICT;

-- A real opening, however many sources list it.
CREATE TABLE job (
    id                 TEXT PRIMARY KEY,            -- StableID of its first listing's canonical URL
    company            TEXT NOT NULL,
    title              TEXT NOT NULL,
    location           TEXT NOT NULL DEFAULT '',
    city               TEXT,
    region             TEXT,                        -- province or state code
    country            TEXT,                        -- CA or US
    remote_scope       TEXT NOT NULL DEFAULT 'unknown',
    salary             TEXT CHECK (salary IS NULL OR json_valid(salary)),
    posted_at          INTEGER,
    description        TEXT NOT NULL DEFAULT '',    -- Markdown
    url                TEXT NOT NULL,
    apply_url          TEXT,
    via                TEXT,
    source_kind        TEXT,
    primary_listing_id TEXT NOT NULL,
    dedup_key          TEXT NOT NULL,
    first_seen_at      INTEGER NOT NULL,
    last_seen_at       INTEGER NOT NULL,
    closed_at          INTEGER,
    decision           TEXT,                        -- saved, skipped
    decided_at         INTEGER,
    archived_at        INTEGER,                     -- out of every list, kept so it isn't new again
    updated_at         INTEGER NOT NULL
) STRICT;

CREATE INDEX job_dedup ON job (dedup_key);
CREATE INDEX job_live ON job (archived_at, closed_at);

-- One source's copy of a job.
CREATE TABLE listing (
    id             TEXT PRIMARY KEY,                -- StableID of its canonical URL
    job_id         TEXT NOT NULL REFERENCES job (id) ON DELETE CASCADE,
    source_id      TEXT NOT NULL,
    canonical_url  TEXT NOT NULL,                   -- what readers compare to skip known jobs' text
    url            TEXT NOT NULL,
    apply_url      TEXT,
    title          TEXT NOT NULL,
    company        TEXT NOT NULL,
    location       TEXT NOT NULL DEFAULT '',
    posted_at      INTEGER,
    content_hash   TEXT NOT NULL,
    first_seen_at  INTEGER NOT NULL,
    last_seen_at   INTEGER NOT NULL,
    missing_streak INTEGER NOT NULL DEFAULT 0,      -- complete answers in a row without it
    closed_at      INTEGER
) STRICT;

CREATE INDEX listing_job ON listing (job_id);
CREATE INDEX listing_source ON listing (source_id, closed_at);

-- What happened to a job: found, posted elsewhere, changed, upgraded, closed, reopened.
CREATE TABLE job_event (
    id          INTEGER PRIMARY KEY,
    job_id      TEXT NOT NULL REFERENCES job (id) ON DELETE CASCADE,
    at          INTEGER NOT NULL,
    kind        TEXT NOT NULL,
    source_kind TEXT,
    detail      TEXT
) STRICT;

CREATE INDEX job_event_job ON job_event (job_id, at);

-- What the AI found in a posting: its requirements and what they mean for you.
CREATE TABLE analysis (
    job_id         TEXT PRIMARY KEY REFERENCES job (id) ON DELETE CASCADE,
    requirements   TEXT NOT NULL CHECK (json_valid(requirements)),
    flags          TEXT NOT NULL CHECK (json_valid(flags)),
    domains        TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(domains)),
    years_required INTEGER,
    seniority      TEXT,
    model          TEXT NOT NULL,
    prompt_version INTEGER NOT NULL,
    analyzed_at    INTEGER NOT NULL
) STRICT;

-- Where screening left a job: dropped by a filter, waiting for the AI, or judged.
CREATE TABLE screening (
    job_id       TEXT PRIMARY KEY REFERENCES job (id) ON DELETE CASCADE,
    stage        TEXT NOT NULL,                     -- filtered, waiting, judged
    verdict      TEXT,                              -- yes, maybe, no; NULL while waiting
    rule         TEXT,                              -- the filter rule or the verdict rule
    reasons      TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(reasons)),
    coverage     TEXT CHECK (coverage IS NULL OR json_valid(coverage)),
    match        REAL,                              -- 0 to 1
    rank         REAL,
    your_verdict TEXT,                              -- you overruled it
    brought_back INTEGER NOT NULL DEFAULT 0,        -- you brought it back from Filtered out
    screened_at  INTEGER NOT NULL
) STRICT;

CREATE INDEX screening_stage ON screening (stage);

-- The master resume: one header row, entries with their bullets, skills.
CREATE TABLE resume_header (
    id            INTEGER PRIMARY KEY CHECK (id = 1),
    full_name     TEXT NOT NULL DEFAULT '',
    email         TEXT NOT NULL DEFAULT '',
    phone         TEXT NOT NULL DEFAULT '',
    linkedin_url  TEXT NOT NULL DEFAULT '',
    github_url    TEXT,
    portfolio_url TEXT,
    city          TEXT,
    region        TEXT,
    country       TEXT,
    headline      TEXT NOT NULL DEFAULT '',
    highlights    TEXT NOT NULL DEFAULT '',
    total_years   REAL,
    version       INTEGER NOT NULL DEFAULT 0,       -- +1 on every change to the master resume
    updated_at    INTEGER NOT NULL
) STRICT;

CREATE TABLE resume_entry (
    id          TEXT PRIMARY KEY,                   -- never changes: builds cite its bullets
    kind        TEXT NOT NULL,
    fields      TEXT NOT NULL CHECK (json_valid(fields)),
    start_month TEXT,                               -- YYYY-MM
    end_month   TEXT,
    is_current  INTEGER NOT NULL DEFAULT 0,
    sort        INTEGER NOT NULL
) STRICT;

CREATE TABLE resume_bullet (
    id       TEXT PRIMARY KEY,                      -- never changes: tailored bullets cite it
    entry_id TEXT NOT NULL REFERENCES resume_entry (id) ON DELETE CASCADE,
    text     TEXT NOT NULL,
    metrics  TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(metrics)),
    skills   TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(skills)),
    sort     INTEGER NOT NULL
) STRICT;

CREATE INDEX resume_bullet_entry ON resume_bullet (entry_id, sort);

CREATE TABLE resume_skill (
    id       TEXT PRIMARY KEY,
    name     TEXT NOT NULL,
    category TEXT NOT NULL DEFAULT '',
    level    TEXT NOT NULL,                         -- proven, can_discuss
    sort     INTEGER NOT NULL
) STRICT;

-- The whole master resume as it was before an import replaced it, to put back.
CREATE TABLE resume_snapshot (
    id      INTEGER PRIMARY KEY,
    at      INTEGER NOT NULL,
    version INTEGER NOT NULL,
    reason  TEXT NOT NULL,
    data    TEXT NOT NULL CHECK (json_valid(data))
) STRICT;

-- A tailored resume (and letter) for one job.
CREATE TABLE build (
    id             TEXT PRIMARY KEY,                -- UUIDv7
    job_id         TEXT NOT NULL REFERENCES job (id),
    mode           TEXT NOT NULL,                   -- strict, lite, stretch
    resume_version INTEGER NOT NULL,                -- the master resume it was written from
    status         TEXT NOT NULL,                   -- queued, running, done, failed, stopped
    wants_letter   INTEGER NOT NULL DEFAULT 0,
    content        TEXT CHECK (content IS NULL OR json_valid(content)),
    letter         TEXT CHECK (letter IS NULL OR json_valid(letter)),
    letter_error   TEXT,
    report         TEXT CHECK (report IS NULL OR json_valid(report)),
    score          REAL,
    error          TEXT,
    created_at     INTEGER NOT NULL,
    started_at     INTEGER,
    finished_at    INTEGER
) STRICT;

CREATE INDEX build_job ON build (job_id, created_at);
CREATE INDEX build_status ON build (status);

CREATE TABLE build_file (
    build_id TEXT NOT NULL REFERENCES build (id) ON DELETE CASCADE,
    kind     TEXT NOT NULL,                         -- resume, letter
    path     TEXT NOT NULL,                         -- relative to the data folder
    sha256   TEXT NOT NULL,
    PRIMARY KEY (build_id, kind)
) STRICT;

-- Jobs you applied to, and what happened since.
CREATE TABLE application (
    id           TEXT PRIMARY KEY,                  -- UUIDv7
    job_id       TEXT NOT NULL UNIQUE REFERENCES job (id),
    build_id     TEXT,
    applied_at   INTEGER NOT NULL,
    channel      TEXT,                              -- "Company site", "Referral", ...
    status       TEXT NOT NULL,                     -- applied, screen, interview, offer, accepted, rejected, ghosted, withdrawn
    status_at    INTEGER NOT NULL,
    follow_up_at INTEGER,
    next_step    TEXT,
    notes        TEXT NOT NULL DEFAULT '',
    updated_at   INTEGER NOT NULL
) STRICT;

CREATE TABLE application_event (
    id             TEXT PRIMARY KEY,
    application_id TEXT NOT NULL REFERENCES application (id) ON DELETE CASCADE,
    kind           TEXT NOT NULL,                   -- a status reached, or "note"
    at             INTEGER NOT NULL,
    note           TEXT
) STRICT;

CREATE INDEX application_event_application ON application_event (application_id, at);

-- Every provider call: counts and codes, never a prompt, a reply or a key.
CREATE TABLE ai_call (
    id             INTEGER PRIMARY KEY,
    at             INTEGER NOT NULL,
    task           TEXT NOT NULL,
    provider       TEXT NOT NULL,
    key_name       TEXT,
    model          TEXT NOT NULL,
    prompt_version INTEGER NOT NULL,
    outcome        TEXT NOT NULL,                   -- ok, invalid, failed, rate_limited, used_up
    error_code     TEXT,
    input_tokens   INTEGER,
    output_tokens  INTEGER,
    ms             INTEGER NOT NULL,
    fell_back      INTEGER NOT NULL DEFAULT 0,
    job_id         TEXT,
    build_id       TEXT,
    daily_limit    INTEGER,
    back_at        INTEGER
) STRICT;

CREATE INDEX ai_call_at ON ai_call (at);
CREATE INDEX ai_call_build ON ai_call (build_id);

-- Validated task outputs, so a step isn't paid for twice.
CREATE TABLE ai_cache (
    task           TEXT NOT NULL,
    input_hash     TEXT NOT NULL,
    prompt_version INTEGER NOT NULL,
    model          TEXT NOT NULL,
    output         TEXT NOT NULL,
    created_at     INTEGER NOT NULL,
    PRIMARY KEY (task, input_hash, prompt_version, model)
) STRICT;

-- Fetches, screenings and builds as runs, for the status line and history.
CREATE TABLE run (
    id          TEXT PRIMARY KEY,
    kind        TEXT NOT NULL,                      -- fetch, screen
    started_at  INTEGER NOT NULL,
    finished_at INTEGER,
    stats       TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(stats)),
    error       TEXT
) STRICT;

CREATE INDEX run_kind ON run (kind, started_at);

-- Every read a fetch made: what search budgets count, and what Sources shows.
CREATE TABLE fetch_log (
    id          INTEGER PRIMARY KEY,
    run_id      TEXT,
    source_id   TEXT NOT NULL,
    at          INTEGER NOT NULL,
    outcome     TEXT NOT NULL,                      -- ok, unchanged, failed, skipped
    http_status INTEGER,
    error       TEXT,
    requests    INTEGER NOT NULL DEFAULT 1,
    items       INTEGER NOT NULL DEFAULT 0,
    added       INTEGER NOT NULL DEFAULT 0,
    changed     INTEGER NOT NULL DEFAULT 0,
    closed      INTEGER NOT NULL DEFAULT 0,
    ms          INTEGER NOT NULL DEFAULT 0
) STRICT;

CREATE INDEX fetch_log_source ON fetch_log (source_id, at);
CREATE INDEX fetch_log_at ON fetch_log (at);

-- Companies a snippet search found hiring at your roles: names to look up on public boards.
CREATE TABLE lead (
    id            TEXT PRIMARY KEY,                 -- StableID of the advert's canonical URL
    company       TEXT NOT NULL,
    title         TEXT NOT NULL,
    location      TEXT NOT NULL DEFAULT '',
    posted_at     INTEGER,
    first_seen_at INTEGER NOT NULL,
    last_seen_at  INTEGER NOT NULL
) STRICT;

CREATE INDEX lead_seen ON lead (last_seen_at);

-- Which public board a company is on, or that none was found (looked up again after 30 days).
CREATE TABLE company_lookup (
    name_key   TEXT PRIMARY KEY,
    kind       TEXT,
    slug       TEXT,
    checked_at INTEGER NOT NULL
) STRICT;

-- When each Google Jobs search (a role phrase in a place) was last made.
CREATE TABLE search_turn (
    key     TEXT PRIMARY KEY,
    last_at INTEGER NOT NULL
) STRICT;
