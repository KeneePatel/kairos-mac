-- 006: what screening found per job (SPEC §6.2): the analysis of its requirements and the verdict
-- trail. Both sync, so each carries updated_hlc and deleted and has no FOREIGN KEY (SPEC §6.1).

-- One analysis per job: the latest. prompt_version says which prompt made it; a newer prompt makes
-- it stale, and the job is analysed again (SPEC §5.5, "Versioned prompts").
CREATE TABLE job_analysis (
    job_id         TEXT PRIMARY KEY,
    requirements   TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(requirements)),
    flags          TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(flags)),  -- sponsorship, clearance, french, remote scope
    domains        TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(domains)),
    years_required INTEGER,
    seniority      TEXT,                                       -- NULL: the posting names no level
    model          TEXT NOT NULL,
    prompt_version INTEGER NOT NULL,
    analyzed_at    INTEGER NOT NULL,
    updated_hlc    TEXT NOT NULL,
    deleted        INTEGER NOT NULL DEFAULT 0 CHECK (deleted IN (0, 1))
) STRICT;

-- Every verdict a job got, and what decided it: a prefilter rule, the analysis, or you.
CREATE TABLE screening (
    id          TEXT PRIMARY KEY,                              -- UUIDv7
    job_id      TEXT NOT NULL,
    stage       TEXT NOT NULL,                                 -- prefilter, analysis, user
    verdict     TEXT NOT NULL,                                 -- yes, maybe, no
    rule_id     TEXT,
    coverage    TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(coverage)),
    reasons     TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(reasons)),
    at          INTEGER NOT NULL,
    updated_hlc TEXT NOT NULL,
    deleted     INTEGER NOT NULL DEFAULT 0 CHECK (deleted IN (0, 1))
) STRICT;

CREATE INDEX screening_job ON screening (job_id);
