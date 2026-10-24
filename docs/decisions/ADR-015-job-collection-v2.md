# ADR-015: Job collection v2 — listings, lifecycle, a board catalog and budgets

## Status
Accepted 2026-10-23 (the owner approved the plan and its four decisions). Supersedes the source
tiers of ADR-005 where they differ.

## Date
2026-10-23

## Context
Kairos watched 19 company boards the owner pasted and read Adzuna's first 50 results for each of
three titles. Adzuna's API gives 500-character snippets, so its jobs couldn't be judged; a job was
stored once and never seen again, so closed postings stayed and copies on two sources weren't
linked. Research (`docs/research/job-collection/`) found public, keyless feeds on nine ATSs, about
500 boards with Canadian jobs discoverable through Common Crawl's index, ETag support on the main
ATSs, and that about a quarter of Adzuna's companies post the same jobs, in full, on a public
board. Canada's own boards (Job Bank, CareerBeacon, Talent.com) offer nothing a personal app may
use; Indeed, LinkedIn and Workday forbid automated access.

## Decision
- **Listings and lifecycle:** each source's copy of a job is a listing; a job keeps them all, is
  seen again, edited, closed (two complete board answers without it) and reopened, and keeps a
  short history. Only a complete, successful answer can close; a 304 repeats the last answer.
- **Sources:** nine public ATS readers (Greenhouse, Lever, Ashby, SmartRecruiters, Workable,
  Recruitee, Personio, BambooHR, Teamtailor), Adzuna paged within a budget, Himalayas, and Google
  Jobs through SerpApi with the owner's key. Workday stays out.
- **Discovery:** a repo script builds a catalog of boards from Common Crawl's index, checked live;
  the app bundles it and watches every board with jobs in the owner's countries. The app never
  crawls.
- **Snippets:** the companies behind snippet jobs are looked up on public boards; a board found
  is watched, and its full posting replaces the snippet. Kairos still never opens Adzuna's paid
  advert links.
- **Roles:** four role families decide searches, the title rule and which new postings are kept.
- **Budgets and logs:** every request is logged; search sources spend within budgets read from
  the log (Adzuna: 200 a day, 950 a week, 2,400 a month).

## Alternatives considered
Scraping Indeed, LinkedIn or Job Bank (their terms forbid it; dropped 2026-10-22); following
Adzuna's advert links (paid clicks for advertisers); Workday's undocumented career-site API (its
terms forbid data mining); crawling in the app (heavy, and Common Crawl already has the URLs); a
paid aggregator such as TheirStack or Coresignal (cost); JSearch (SerpApi covers Google for Jobs).

## Consequences
- Coverage grows from 19 boards and 150 Adzuna results to hundreds of boards and every Adzuna
  posting at the owner's roles; most jobs carry their full text.
- A fetch makes more requests (mostly 304s) and takes about a minute; quiet catalog boards rest.
- The catalog must be refreshed with releases (`python3 -I scripts/discover-boards.py`).
- Migrations 011–014; SPEC §5.2, §5.4 and §6.2 updated.
