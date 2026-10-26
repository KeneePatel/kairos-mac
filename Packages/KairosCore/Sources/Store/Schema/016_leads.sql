-- 016: leads (job collection v3, C2, ADR-018): what a search that sends snippets (Adzuna) found,
-- kept as company names to look up on public boards, never as jobs. Local, trimmed after 30 days.
CREATE TABLE lead (
    id            TEXT PRIMARY KEY,                           -- hash of the posting's canonical URL
    source_id     TEXT NOT NULL,
    company       TEXT NOT NULL,
    title         TEXT NOT NULL,
    location      TEXT NOT NULL DEFAULT '',
    posted_at     INTEGER,
    first_seen_at INTEGER NOT NULL,
    last_seen_at  INTEGER NOT NULL
) STRICT;

CREATE INDEX lead_company ON lead (company);
CREATE INDEX lead_seen ON lead (last_seen_at);

-- Jobs Kairos only ever saw as a snippet step aside: it keeps whole postings now. Ones you acted
-- on stay.
UPDATE job SET state = 'archived'
WHERE deleted = 0 AND state = 'new' AND description_kind = 'snippet';
