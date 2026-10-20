-- 005: the local-only sensitive profile (SPEC §6.2, `private_setting`; §5.9): work authorization per
-- country and security clearance. Never synced, by design: it has no updated_hlc or deleted column,
-- so the sync outbox has nothing to pick up. Values are JSON documents owned by the module reading them.

CREATE TABLE private_setting (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL CHECK (json_valid(value))
) STRICT;
