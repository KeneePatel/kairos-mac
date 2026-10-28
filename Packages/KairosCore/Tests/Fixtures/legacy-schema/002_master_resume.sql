-- 002: the master resume (SPEC §5.10, §6.2). All four tables sync.
--
-- Months are TEXT 'YYYY-MM'. Entry fields are a JSON object whose shape depends on `kind`; the
-- MasterResume module owns those shapes. Bullet and entry ids never change once made, because
-- tailored bullets cite them.

CREATE TABLE resume_contact (
    id             TEXT PRIMARY KEY,                          -- always 'contact': one per account
    full_name      TEXT NOT NULL DEFAULT '',
    email          TEXT NOT NULL DEFAULT '',
    phone_e164     TEXT NOT NULL DEFAULT '',
    linkedin_url   TEXT NOT NULL DEFAULT '',
    github_url     TEXT,
    portfolio_url  TEXT,
    city           TEXT,
    region         TEXT,
    country        TEXT,
    headline       TEXT NOT NULL DEFAULT '',
    highlights     TEXT NOT NULL DEFAULT '',
    total_years    REAL,
    master_version INTEGER NOT NULL DEFAULT 0,                -- +1 on every save to any master-resume table
    updated_hlc    TEXT NOT NULL,
    deleted        INTEGER NOT NULL DEFAULT 0 CHECK (deleted IN (0, 1))
) STRICT;

CREATE TABLE resume_entry (
    id          TEXT PRIMARY KEY,                             -- UUIDv7
    kind        TEXT NOT NULL,                                -- experience, project, education, certification, ...
    fields      TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(fields)),
    start_month TEXT,
    end_month   TEXT,
    is_current  INTEGER NOT NULL DEFAULT 0 CHECK (is_current IN (0, 1)),
    sort        INTEGER NOT NULL DEFAULT 0,                   -- order within its kind
    updated_hlc TEXT NOT NULL,
    deleted     INTEGER NOT NULL DEFAULT 0 CHECK (deleted IN (0, 1))
) STRICT;

CREATE TABLE resume_bullet (
    id          TEXT PRIMARY KEY,                             -- UUIDv7; cited by tailored bullets
    entry_id    TEXT NOT NULL,
    text        TEXT NOT NULL,
    metrics     TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(metrics)),   -- ["40% faster", "$2M saved"]
    skills      TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(skills)),    -- skill names used
    sort        INTEGER NOT NULL DEFAULT 0,
    updated_hlc TEXT NOT NULL,
    deleted     INTEGER NOT NULL DEFAULT 0 CHECK (deleted IN (0, 1))
) STRICT;

CREATE INDEX resume_bullet_entry ON resume_bullet (entry_id) WHERE deleted = 0;

CREATE TABLE skill (
    id          TEXT PRIMARY KEY,                             -- UUIDv7
    name        TEXT NOT NULL,
    category    TEXT NOT NULL DEFAULT '',                     -- language, framework, cloud, tool, ...
    level       TEXT NOT NULL DEFAULT 'proven',               -- proven, can_discuss
    sort        INTEGER NOT NULL DEFAULT 0,
    updated_hlc TEXT NOT NULL,
    deleted     INTEGER NOT NULL DEFAULT 0 CHECK (deleted IN (0, 1))
) STRICT;
