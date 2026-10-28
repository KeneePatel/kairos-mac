-- 010: each provider call by key, for the usage bars in AI providers (2026-10-23). Gemini says
-- nothing about a key's quota until it refuses, so Kairos counts its own calls per key and keeps
-- what a refusal said. Local only like llm_call: a key's name in the key store, never the key.

CREATE TABLE llm_key_call (
    id            INTEGER PRIMARY KEY,
    at            INTEGER NOT NULL,                  -- milliseconds since 1970
    provider      TEXT NOT NULL,
    key_name      TEXT NOT NULL,
    model         TEXT NOT NULL,
    outcome       TEXT NOT NULL,                     -- answered, failed, used_up
    input_tokens  INTEGER,
    output_tokens INTEGER,
    daily_limit   INTEGER,                           -- the limit a day's refusal named
    back_at       INTEGER                            -- when that refusal said the key serves the model again
) STRICT;

CREATE INDEX llm_key_call_at ON llm_key_call (at);
