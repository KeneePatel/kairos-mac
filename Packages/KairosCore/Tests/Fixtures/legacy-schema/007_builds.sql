-- 007: tailored builds and their files (SPEC §6.2, `build` and `artifact`). Both sync, so each
-- carries updated_hlc and deleted and has no FOREIGN KEY (SPEC §6.1).

CREATE TABLE build (
    id             TEXT PRIMARY KEY,                           -- UUIDv7
    job_id         TEXT NOT NULL,
    mode           TEXT NOT NULL,                              -- strict, lite, stretch
    master_version INTEGER NOT NULL,                           -- the master resume it was built from
    status         TEXT NOT NULL,                              -- queued, running, done, failed
    template_id    TEXT NOT NULL DEFAULT 'classic',
    content        TEXT CHECK (content IS NULL OR json_valid(content)),          -- bullets carry source_ids
    match_score    REAL,
    breakdown      TEXT CHECK (breakdown IS NULL OR json_valid(breakdown)),
    iterations     INTEGER NOT NULL DEFAULT 0,                 -- rewrite passes
    cover_letter   TEXT CHECK (cover_letter IS NULL OR json_valid(cover_letter)),
    error          TEXT,
    created_at     INTEGER NOT NULL,
    finished_at    INTEGER,
    updated_hlc    TEXT NOT NULL,
    deleted        INTEGER NOT NULL DEFAULT 0 CHECK (deleted IN (0, 1))
) STRICT;

CREATE INDEX build_job ON build (job_id) WHERE deleted = 0;
CREATE INDEX build_status ON build (status) WHERE deleted = 0;

CREATE TABLE artifact (
    id           TEXT PRIMARY KEY,                             -- UUIDv7
    build_id     TEXT NOT NULL,
    kind         TEXT NOT NULL,                                -- resume, cover_letter
    sha256       TEXT NOT NULL,
    storage_path TEXT,                                         -- in Supabase Storage, once synced
    local_path   TEXT,                                         -- on this Mac
    updated_hlc  TEXT NOT NULL,
    deleted      INTEGER NOT NULL DEFAULT 0 CHECK (deleted IN (0, 1))
) STRICT;

CREATE INDEX artifact_build ON artifact (build_id);
