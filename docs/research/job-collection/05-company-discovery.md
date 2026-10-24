# Finding companies' boards (research, 2026-10-23)

ATS feeds give full postings, but only for companies Kairos knows. Today that is the 19 the
owner pasted. How can Kairos know the companies that hire in Canada?

## Common Crawl's URL index (free, public)

Common Crawl publishes a URL index for each monthly crawl
(`index.commoncrawl.org/{crawl}-index?url={host}/*&output=json`). Listing the board hosts
gives company slugs; each slug is then checked once against the ATS's own public API.
Open-source job tools do exactly this (github.com/rishilahoti/ashby-job-scraper,
github.com/repomesh/ashby-job-scraper); Lever's robots.txt keeps Common Crawl's bot out, so
Lever is under-represented (github.com/EliasNAires/oneprofile issues 74 and 78).

**Measured on crawl CC-MAIN-2026-43 (2026-10-23):**

| ATS host | Index pages | Distinct board slugs |
|---|---|---|
| job-boards.greenhouse.io + boards.greenhouse.io | 5 + 2 | 2,665 |
| jobs.ashbyhq.com | 1 | ~425–1,100 (case variants) |
| apply.workable.com | 2 | 1,147 |
| jobs.smartrecruiters.com | 1 | 672 |
| jobs.lever.co | 1 | 267 |

The index server sometimes answers 504; a script must retry. Older crawls and the Wayback
Machine add more slugs, mostly dead ones (oneprofile #78: 12–17% of Wayback-only slugs live).

**Sampled for Canada** (random boards, public list endpoints, 2026-10-23):

| ATS | Sampled | Live | With any Canadian job | Canadian jobs |
|---|---|---|---|---|
| Greenhouse | 150 | 124 | 20 (16%) | 133 |
| Lever | 50 | 38 | 8 (21%) | 116 |
| Ashby | 60 | 60 | 12 (20%) | 113 |
| Workable | 50 | 45 | 4 (9%) | 15 |
| SmartRecruiters | 50 | 49 | 8 (16%) | 132 (first 100 per board) |

Projected from one crawl: about **500 boards with Canadian jobs holding about 4,000
Canadian postings** (all occupations), against 19 boards today. Location matching here was a
rough regex (city names, province codes, "Canada").

## Cheap to watch hundreds of boards

Measured on Stripe's Greenhouse board and others (2026-10-23):

| Request | Bytes |
|---|---|
| Greenhouse list **without** `content=true` | 39 KB |
| Greenhouse list with `content=true` | 1.98 MB |
| Greenhouse list again with `If-None-Match` (ETag) | **304, 0 bytes** |
| Lever `spotify` | 851 KB; 304 with ETag |
| Ashby `ramp` | 2.8 MB; 304 with ETag |

So a board that didn't change costs one tiny request, and Greenhouse's light list lets
Kairos read titles and places first and download the full text only for jobs worth
screening (`GET /v1/boards/{token}/jobs/{id}?pay_transparency=true`).

## Other ways to find boards

1. **From search results**: every Adzuna result names a company. Kairos can look for that
   company's board by trying slug candidates on the public APIs (Greenhouse, Lever, Ashby,
   SmartRecruiters, Workable, Recruitee): a handful of requests per new company, cached. A
   hit both upgrades the Adzuna snippet to the full posting and adds a board.
2. **From a pasted careers page**: the page's HTML names the ATS it embeds (Greenhouse
   `gh_jid`/embed script, Lever, Ashby `ashby_jid`, Workable, Teamtailor assets).
3. **Search engines**: Google's Programmable Search JSON API closes 2027-01-01 to existing
   users and accepts no new ones; Brave's API costs per query. Not needed given 1 and the crawl.
4. **Curated lists** (startup lists, accelerator portfolios): useful seeds, stale fast
   (oneprofile #74: 27 of 60 Lever slugs live).

## What this means for Kairos

- A **board catalog**: a script in the repo (`scripts/discover-boards`) reads the latest
  crawl's index, checks each board once, and keeps those with Canadian or US jobs, with
  their company name, ATS and counts. The app ships the result as a resource and refreshes it
  with releases; it never crawls on its own.
- The app adds boards three ways: the catalog, a pasted URL, and companies seen in search
  results. Each board remembers its ETag, how often it has relevant jobs, and whether it's
  gone (404 several times) so dead boards drop out.

## Built (J5, 2026-10-24)

`scripts/discover-boards.py` read CC-MAIN-2026-43 and checked 7,549 candidate boards, then 1,811
Workable and SmartRecruiters slugs whose index queries had timed out. The catalog kept 3,672
boards: **808 with Canadian jobs** (11,441 postings) and 3,434 with US jobs. Canadian boards by
ATS: Greenhouse 260, Ashby 164, SmartRecruiters 143, BambooHR 101, Workable 76, Lever 44,
Recruitee 19, Personio 1, Teamtailor 0.

Lessons:
- Common Crawl's index answers 504 often; one query per host can return nothing. Retry, and keep
  slugs from earlier runs (`--extra`).
- Job sites and agencies run public boards too (Jobgether: 4,147 jobs, 333 Canadian; an agency's
  Lever board: 3,752): they repost other companies' jobs and are left out by name.
- Watching 600 boards: the first fetch read 599 sources in 3.5 minutes (44,697 postings scanned,
  403 new at the owner's roles); afterwards boards with nothing for the owner rest three days and
  the rest mostly answer 304.
