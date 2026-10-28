-- 008: jobs you applied to and their timelines (SPEC §6.2, `application` and `application_event`;
-- T45). Both sync, so each carries updated_hlc and deleted and has no FOREIGN KEY (SPEC §6.1).
-- Events are insert-only: a status change appends one, and nothing edits one (SPEC §6.4, 6).

CREATE TABLE application (
    id             TEXT PRIMARY KEY,                           -- UUIDv7
    job_id         TEXT NOT NULL,
    build_id       TEXT,                                       -- the build you sent, when Kairos made it
    applied_at     INTEGER NOT NULL,                           -- ms since 1970
    channel        TEXT,                                       -- where you applied: "Greenhouse", "Referral"…
    status         TEXT NOT NULL,                              -- applied, screen, interview, offer, accepted,
                                                               -- rejected, ghosted, withdrawn
    status_at      INTEGER NOT NULL,                           -- when it reached that status
    next_action_at INTEGER,                                    -- a follow-up reminder
    next_action    TEXT,
    notes          TEXT NOT NULL DEFAULT '',
    updated_hlc    TEXT NOT NULL,
    deleted        INTEGER NOT NULL DEFAULT 0 CHECK (deleted IN (0, 1))
) STRICT;

CREATE UNIQUE INDEX application_job ON application (job_id) WHERE deleted = 0;

CREATE TABLE application_event (
    id             TEXT PRIMARY KEY,                           -- UUIDv7
    application_id TEXT NOT NULL,
    kind           TEXT NOT NULL,                              -- a status the application reached, or "note"
    at             INTEGER NOT NULL,
    note           TEXT,
    updated_hlc    TEXT NOT NULL,
    deleted        INTEGER NOT NULL DEFAULT 0 CHECK (deleted IN (0, 1))
) STRICT;

CREATE INDEX application_event_application ON application_event (application_id, at);
