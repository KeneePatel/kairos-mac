-- 004: non-secret settings (SPEC §6.2, `setting`). Synced. Values are JSON documents owned by the
-- module that reads them, such as "llm" (providers, key *names*, model routing, budget). Secrets
-- never come here: keys live in the Keychain.

CREATE TABLE setting (
    key         TEXT PRIMARY KEY,
    value       TEXT NOT NULL CHECK (json_valid(value)),
    updated_hlc TEXT NOT NULL,
    deleted     INTEGER NOT NULL DEFAULT 0 CHECK (deleted IN (0, 1))
) STRICT;
