-- 003: the LLM layer's local tables (SPEC §5.5, Observability; §6.2). Neither syncs and neither
-- ever holds a key, a prompt or a reply's personal content: llm_call keeps counts and codes only,
-- and llm_cache keeps validated task outputs so a step isn't paid for twice.

CREATE TABLE llm_call (
    id             INTEGER PRIMARY KEY,
    at             INTEGER NOT NULL,                  -- milliseconds since 1970
    task_id        TEXT NOT NULL,
    provider       TEXT NOT NULL,
    model          TEXT NOT NULL,
    prompt_version INTEGER NOT NULL,
    input_tokens   INTEGER,
    output_tokens  INTEGER,
    latency_ms     INTEGER NOT NULL,
    attempt        INTEGER NOT NULL,                  -- provider calls this row covers
    outcome        TEXT NOT NULL,                     -- ok, repaired, rate_limited, fell_back, failed
    error_code     TEXT,
    job_id         TEXT,
    build_id       TEXT
) STRICT;

CREATE INDEX llm_call_at ON llm_call (at);

CREATE TABLE llm_cache (
    task_id        TEXT NOT NULL,
    input_hash     TEXT NOT NULL,                     -- SHA-256 of the rendered messages
    prompt_version INTEGER NOT NULL,
    model          TEXT NOT NULL,
    output         TEXT NOT NULL CHECK (json_valid(output)),
    created_at     INTEGER NOT NULL,
    PRIMARY KEY (task_id, input_hash, prompt_version, model)
) STRICT;
