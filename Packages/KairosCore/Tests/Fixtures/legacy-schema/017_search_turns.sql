-- 017: a search engine's turns (job collection v3, C3): when each role-and-place pair was last
-- searched on Google Jobs, so a fetch asks the least recent ones first and every pair comes round
-- about every five days on SerpApi's free plan. Local.
CREATE TABLE search_turn (
    source_id TEXT NOT NULL,
    key       TEXT NOT NULL,                               -- phrase|place|country
    last_at   INTEGER NOT NULL,
    PRIMARY KEY (source_id, key)
) STRICT;
