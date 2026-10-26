# Job collection research

Research for the job collection redesign (started 2026-10-23). Each file is a dated snapshot:
facts with their sources, then what they mean for Kairos. Check a fact again before relying on
it after a few months; APIs and terms change.

| File | Question it answers |
|---|---|
| [00-current-system.md](00-current-system.md) | How Kairos finds, stores and screens jobs today, and what the owner's database shows |
| [01-adzuna.md](01-adzuna.md) | What Adzuna's API returns, allows and limits |
| [02-ats-public-apis.md](02-ats-public-apis.md) | Which applicant tracking systems publish open jobs without a key, and their quirks |
| [03-search-apis.md](03-search-apis.md) | Other cross-company sources (Himalayas, Remotive, The Muse, JSearch, SerpApi, Jooble…), with measured Adzuna volumes |
| [04-canada-sources.md](04-canada-sources.md) | Canadian boards (Job Bank, WorkBC, CareerBeacon, Talent.com…) and pay-transparency laws |
| [05-company-discovery.md](05-company-discovery.md) | How to find which companies to watch (Common Crawl, search results), measured |
| [06-job-tracking.md](06-job-tracking.md) | Identity, matching copies, lifecycle and records |
| [07-v3-findings.md](07-v3-findings.md) | What v2 yielded on the owner's data (2026-10-26), one SerpApi search's shape, and every source checked again |

The plan built on this: [`docs/design/job-collection.md`](../../design/job-collection.md); the decision:
[`ADR-015`](../../decisions/ADR-015-job-collection-v2.md). The v3 redesign (2026-10-26): [`docs/design/job-collection-v3.md`](../../design/job-collection-v3.md), ADR-018. The catalog script is
`scripts/discover-boards.py`.

Tools: `Kairos --adzuna-probe` (a few Adzuna searches, counts only), `Kairos --fetch-dry
[--add=<careers URL>|--add=himalayas] [--adzuna-budget=<n>]` (two fetches on a migrated copy of the
database, no AI calls), `Kairos --coverage-report` (where jobs come from), `Kairos --sources-report` (what each kind yields, verdicts, link hosts, lookups, boards by origin), `Kairos --serpapi-probe[=<query>] [--place=<city>]` (one Google Jobs search's shape, one of the plan's searches), and
`scripts/discover-boards.py` (the board catalog).
