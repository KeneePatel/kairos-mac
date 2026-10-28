-- 014: which public board a search's company is on, or that none was found (job collection v2,
-- J6). Local: a cache, so a company is looked up once, and again a month later if nothing was
-- found.

CREATE TABLE company_lookup (
    name_key   TEXT PRIMARY KEY,                           -- the company name, folded
    kind       TEXT,                                       -- the board found, or NULL
    slug       TEXT,
    checked_at INTEGER NOT NULL
) STRICT;
