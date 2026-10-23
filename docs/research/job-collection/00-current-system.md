# Job collection today (as of 2026-10-23, main 058536a)

How Kairos finds, stores and screens jobs right now, read from the code and from the owner's
own database (`Kairos --screening-report`, 2026-10-23). This is the baseline the redesign starts
from. Later documents in this folder are research; `../../design/job-collection.md` is the plan.

## 1. Sources

`Packages/KairosCore/Sources/JobSources/`. A `JobSource` only fetches and maps; it never writes.

| Kind | How | What it returns | Code |
|---|---|---|---|
| Greenhouse | `GET boards-api.greenhouse.io/v1/boards/{token}/jobs?content=true` | every open job of one company, full HTML description | `GreenhouseSource` |
| Lever | `GET api.lever.co/v0/postings/{slug}?mode=json` | every open job of one company, full description | `LeverSource` |
| Ashby | `GET api.ashbyhq.com/posting-api/job-board/{org}` | every listed job of one company, full description | `AshbySource` |
| Adzuna | `GET api.adzuna.com/v1/api/jobs/{ca,us}/search/1?title_only=<title>&sort_by=date&max_days_old=<n>&results_per_page=50` | search results across companies, **a snippet of each description** | `AdzunaSource` |
| LinkedIn, Indeed CA/US, Glassdoor, Google Jobs, Wellfound, Job Bank | enum cases only | — | dropped 2026-10-22 (T41–T43): Cloudflare bot check, and their terms forbid automated access |

- Company boards are added by pasting a careers URL; `ATSDetector` recognises Greenhouse,
  Lever and Ashby hosts and extracts the slug. Nothing else is recognised.
- There is no way to find companies: the watchlist is whatever the owner pasted (19 boards on
  2026-10-23: GitLab, Spotify, Ramp, Affirm, Lyft, Stripe, Lightspeed, 1Password, Cohere,
  Tailscale, Pinterest, Robinhood, Kepler, Mozilla, Instacart, Samsara, Brex, Snowflake, Sentry).
- Adzuna, as configured: one search per (country, title) pair, at most 20 a run, **page 1 only**
  (50 results), title-only match, newest first, `max_days_old` = the Fetch screen's "Posted"
  limit. The owner's settings make that 3 searches (Canada × "Software Engineer", "Software
  Developer", "Developer"), so at most 150 results a run.
- Adzuna's `description` is a snippet (about 500 characters). Kairos deliberately never opens
  the advert's `redirect_url` (T40: "advertisers pay for those clicks"), so an Adzuna job never
  gets its full text.

## 2. Fetch run (`Pipeline/FetchRun.swift`)

1. Every enabled source, company boards first, then search sources, at most 4 at a time.
2. Postings older than the "Posted" limit are skipped; undated ones are kept.
3. `Normalizer`: canonical URL (tracking parameters stripped; an Adzuna ad's query dropped),
   HTML to Markdown, `Geo.parse` for country, region, city and remote scope. Postings whose
   places are all outside Canada and the US are dropped.
4. `Deduplicator`: drop ids already stored (`knownIDs`), then near-duplicates from *another*
   source whose `company|title|city` key is ≥ 0.9 similar (Levenshtein).
5. Store new jobs only. **A job already stored is never touched again**: no "seen again", no
   updated description, no closing.
6. `Retention`: untouched jobs archived at 60 days, tombstoned at 120. AI logs trimmed at 30.
7. Source health: 3 runs in a row with zero results marks a source "degraded".

## 3. Storage (`job` table, migration 001 + 009)

- `id` = first 16 bytes of SHA-256(canonical URL). One row per URL.
- One `source_id` and one `url` per job: the first source that stored it.
- `description` Markdown (the snippet, for Adzuna), `posted_at`, `first_seen_at`.
- No `last_seen_at`, no `closed_at`, no description origin or completeness, no link between
  copies of one job on different sources, no salary parsing (columns exist, never filled).
- `state`: new, shortlisted, skipped, applied, archived. `cleared` (009) for "Delete all jobs".

## 4. Screening (`Pipeline/ScreeningRun.swift`, `Screening/`)

1. **Prefilter** (free, deterministic; first failing rule wins): title include and exclude,
   seniority from the title, years required, location, remote scope, work authorization,
   clearance, French, blacklist, posting age, already applied.
2. **Analyze**: one AI call per survivor (`AnalyzeJobTask`), cached per job and prompt version.
3. **Verdict** in code (`VerdictEngine`). A job from a "snippet source" (every Adzuna source)
   can't be Yes: a strong match becomes Maybe with rule `snippet_only`.
4. **Rank**: verdict, then country priority, then match.

## 5. What the owner's database shows (395 jobs, 2026-10-23)

| Finding | Evidence | Cause |
|---|---|---|
| Most Adzuna results are noise | 263 jobs dropped by `title_include`, e.g. "Business Development Manager", "Learning & Development Analyst Student" | `title_only=Developer` matches "Development"; Adzuna stems words |
| Real developer jobs dropped | "Software Development Engineer, Navigator · Amazon" dropped by `title_include` | the include rule is a literal phrase match: "Software Development Engineer" contains none of "Software Engineer", "Software Developer", "Developer" |
| Adzuna jobs can't be judged | 28 jobs at Maybe with `snippet_only` | snippet only, by design |
| Odd Adzuna locations | "Regent Park, City of Toronto", "CN Tower, City of Toronto" | Adzuna geocodes to neighbourhoods/landmarks |
| Coverage is narrow | 19 companies on boards; Adzuna capped at 150 results a run, page 1 only | no discovery, no pagination |
| Agencies dominate Adzuna | Innosystech 13, Maarut 9, vTech 3, Cleo Consulting 2, Teckhorizon 2 | aggregator mix; no company quality signal |

## 6. Gaps the redesign has to close

1. **Coverage**: no company discovery; Adzuna limited to 3 × 50 results; no other sources.
2. **Description quality**: Adzuna snippets are never upgraded, even when the same job is on
   the company's own public board.
3. **Query quality**: title-only search on short words ("Developer") pulls in unrelated work;
   the title filter misses common variants (SDE, "Software Development Engineer", "Full Stack",
   "Backend", "Programmer Analyst").
4. **Tracking**: no last-seen or closed state, no history, no cross-source links, first copy
   wins forever, no per-source fetch log beyond counts.
5. **Observability**: no per-source, per-query record of what a run returned, so coverage
   can't be measured or debugged.
