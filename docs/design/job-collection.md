# Job collection v2: design and plan

Status: **approved 2026-10-23** with the owner's four decisions:

1. **Companies**: watch every catalog company with jobs in your countries (plus pasted ones and
   ones found through Adzuna), each mutable.
2. **Roles**: software development; DevOps, cloud and SRE; data, ML and AI engineering; QA and
   test automation.
3. **Sources**: the free ones (public boards, Adzuna, Himalayas) **and** Google Jobs through
   JSearch or SerpApi with the owner's own key.
4. **Adzuna**: use most of the free plan (up to 200 searches a day, 2,400 a month).

 Research behind every
choice: `docs/research/job-collection/` (00 current system, 01 Adzuna, 02 public ATS APIs,
03 search APIs, 04 Canadian sources, 05 company discovery, 06 tracking).

## Goals

1. **Coverage**: find nearly every posting in the owner's countries and roles that a
   personal app may read, not just 19 companies and Adzuna's first 150 results.
2. **Full text**: as many jobs as possible screened on the whole posting, not a snippet.
3. **Tracking**: every job knows where it's posted, when it was first and last seen, whether
   it changed, and whether it closed, and keeps that record after it's gone.
4. **Robustness**: a source failing, slowing down or changing shape never loses or wrongly
   closes jobs; every request is logged; budgets are kept.
5. **Within the rules**: only public APIs and feeds, polite rates, no bot-check evasion, no
   automated visits to sites whose terms forbid them (Indeed, LinkedIn, Job Bank, Workday
   stay out, as decided 2026-10-22). Adzuna's paid advert links are never opened automatically.

## Where jobs come from

| Source | Role | Full text | Cost |
|---|---|---|---|
| **Public ATS boards**: Greenhouse, Lever (global + EU), Ashby, SmartRecruiters, Workable, Recruitee, Personio, BambooHR, Teamtailor | the backbone: every job a watched company has open | yes | free, keyless; ETag means an unchanged board costs one tiny request |
| **Board catalog** (new) | which companies to watch: boards with jobs in your countries, found from Common Crawl's URL index and checked against each ATS, shipped with the app | — | built by a repo script; the app never crawls |
| **Adzuna** (rebuilt) | everything else: agencies, Job Bank and Workday employers, small companies | snippet, upgraded when the job is found on a public board | free key: 250 a day, 2,500 a month |
| **Himalayas** (new, optional) | remote roles open to Canada | yes | free key |
| JSearch or SerpApi (owner's decision) | LinkedIn, Indeed and Workday jobs as Google for Jobs shows them | yes | ~100–250 free searches a month; a third party queries Google |

## Structure

```
JobSources (fetch and map; never writes)
 ├─ BoardSource protocol: greenhouse, lever, ashby, smartrecruiters, workable, recruitee,
 │    personio, bamboohr, teamtailor; each: list(conditional) → [ListingStub],
 │    details(stub) → Posting when the list has no text
 ├─ SearchSource protocol: adzuna, himalayas (, jsearch); each: plan(queries, budget) → pages
 ├─ ATSDetector: all of the above, from a pasted URL or a careers page's HTML
 ├─ BoardCatalog: the bundled resource (company, ATS, slug, countries, counts)
 └─ CompanyFinder: company name → board, by catalog lookup, then slug probes (cached)
Pipeline
 └─ FetchRun v2: plan (boards due, Adzuna queries within budget) → fetch (per-host limits,
      conditional) → role gate → normalize → match to existing listings and jobs →
      upsert listings, update lifecycle → snippet upgrades → log every request
Store
 ├─ listing (new): one row per source copy of a job
 ├─ job: + last_seen_at, closed_at, description_kind, primary_listing_id, apply_url
 ├─ job_event (new): found, seen elsewhere, changed, upgraded, closed, reopened
 ├─ source: + origin, etag, last_ok_at, failures, misses, relevant_count, cadence
 └─ fetch_log (new, local only, 30 days): every request, for coverage and budgets
Screening
 ├─ role families instead of literal title phrases (fixes "Software Development Engineer")
 └─ snippet rule reads job.description_kind; a job whose text changes or upgrades is re-screened
```

## Data model (migration 011)

**`listing`** (syncs, except `description`, which stays on this Mac):
`id` (hash of the source's own id, or of the canonical URL), `job_id`, `source_id`,
`external_id`, `url`, `canonical_url`, `title`, `company`, `location`, `posted_at`,
`description`, `description_kind` (full, snippet, none), `content_hash`, `salary` JSON,
`first_seen_at`, `last_seen_at`, `missing_runs`, `closed_at`, `updated_hlc`, `deleted`.

**`job`** keeps its id rule (hash of its first canonical URL) so ids stay stable, and gains
`last_seen_at`, `closed_at`, `description_kind`, `primary_listing_id`, `apply_url`. Its
description is the primary listing's: the board's full text beats a snippet; a company board
beats an aggregator.

**`job_event`** (syncs): `job_id`, `at`, `kind`, `detail` (which source, what changed).

**`source`** gains `origin` (pasted, catalog, found_via_search), `etag`, `last_modified`,
`last_ok_at`, `fail_runs`, `relevant_count`, `cadence`, `gone_at`.

**`fetch_log`** (local): `run_id`, `source_id`, `request` (board, or query and page), `at`,
`status`, `http_status`, `not_modified`, `bytes`, `items`, `new`, `changed`, `closed`,
`ms`.

Backfill: every existing job gets one listing with the same id; Adzuna jobs are `snippet`.

## Rules

- **Lifecycle** (06): only a successful, complete board answer can close; two complete
  misses in a row close a listing; a 304 marks everything seen; search listings close only
  as "probably closed" (not seen 30 days, posted over 45 days ago); a job closes when all its
  listings do; closing never deletes, and closed jobs leave Review but stay on builds and
  applications with a Closed mark.
- **Matching copies** (06): same normalized company, compatible place, similar normalized
  title; then text containment (snippet in full) or shingle overlap (full vs full). A match
  attaches a listing instead of dropping it.
- **Role gate at fetch**: a board's jobs whose titles match none of your role families are
  counted ("312 at other roles") but not stored, so 500 boards don't flood the database.
  Changing your roles clears the boards' ETags so the next fetch re-reads them.
- **Adzuna plan**: one `title_only` search per role phrase per country, newest first,
  `max_days_old` = days since the last good run + 1; page until a page is all known, the
  results end, or the run's page budget is spent. Noise excluded with `what_exclude`.
  Budget from the fetch log: stays under 200 a day and 2,400 a month by default, shown as a
  bar like the AI keys'. Places read from `location.area`, not the landmark display name.
- **Snippet upgrade**: a new Adzuna job's company is looked up in the catalog, then probed
  on public boards (two slug guesses × six ATS, result cached 30 days, at most 40 companies a
  run). A board found is watched from then on (origin "found via Adzuna"); a matching posting
  replaces the snippet, and the job is re-screened.
- **Politeness**: at most 2 requests at a time per host, a short gap between requests,
  `Retry-After` honoured, an identifying User-Agent, 304s preferred. Boards with relevant jobs
  in the last 60 days are fetched every run; quiet ones every third day; a board answering
  404 three runs in a row is marked gone.
- **Failures**: one source failing never stops the run; its listings stay as they were.

## What you'll see

- **Find jobs**: per-source results (new, changed, closed, upgraded), the Adzuna budget bar,
  and a Companies list: catalog companies, ones you pasted, ones found through Adzuna, with
  their status (watching, quiet, muted, gone).
- **Job screen**: "Where it's posted" (each source, linked), first and last seen, Closed
  mark, where the description came from ("Full posting from Syndio's Greenhouse board" or
  "Adzuna snippet"), and a short history.
- **Review**: closed jobs leave the list; a filter shows them.
- `Kairos --coverage-report`: per source and query, what was found, new, missed and why.

## Phases (each its own PR with the full gate)

| # | Phase | Delivers |
|---|---|---|
| 1 | Tracking foundation | migration 011 and backfill; listings; lifecycle; job events; fetch log; conditional requests; Greenhouse light list + detail with pay; Lever `on-site` fix and EU host; job screen "where posted, seen, closed" |
| 2 | More public boards | SmartRecruiters, Workable, Recruitee, Personio, BambooHR, Teamtailor readers with recorded fixtures; detector for all of them; Workday URLs explained, not fetched |
| 3 | Roles | role families with variants and exclusions; title rule and fetch gate use them; Settings, Search shows them |
| 4 | Adzuna v2 | query plan, pagination, incremental days, area parsing, budget and its bar |
| 5 | Board catalog | `scripts/discover-boards` (Common Crawl index + live checks), bundled catalog, Companies list, auto-watch, cadence, gone boards |
| 6 | Snippet upgrade | company finder, listing matching, upgrade and re-screen |
| 7 | Optional sources | Himalayas (and Remotive); JSearch or SerpApi only if chosen |
| 8 | Coverage and docs | `--coverage-report`, SPEC §5.2/5.4/6.2 updates, ADR-015 |

Every phase: test first, recorded fixtures for every new source (no network in tests),
lifecycle and matching tests, a migration test on a copy of the owner's database, the
snapshot of each changed screen, and a live check against the real sources.
