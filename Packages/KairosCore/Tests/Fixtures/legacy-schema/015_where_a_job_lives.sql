-- 015: where a job lives (job collection v3, C1, ADR-018): the page Open posting opens, apart from
-- the job's identity URL, and the site the posting was taken from ("Scotiabank", "LinkedIn").
-- Both sync with the job.
ALTER TABLE job ADD COLUMN apply_url TEXT;
ALTER TABLE job ADD COLUMN via TEXT;

-- Jobs stored with Google's search page as their link (Google Jobs before v3) step aside: the next
-- fetch stores the same postings again with the page each was taken from. Ones you acted on keep
-- their verdict and history.
UPDATE job SET state = 'archived'
WHERE deleted = 0 AND state = 'new' AND url LIKE 'https://www.google.com/%';
