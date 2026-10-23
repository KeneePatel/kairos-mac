# Cross-company search APIs (research, 2026-10-23)

Sources that search many employers at once. They find jobs at companies Kairos doesn't know,
but most give snippets, cost money past a small free tier, or reach the data in ways Kairos's
own rules don't allow. Adzuna is covered in 01-adzuna.md.

## Measured: what Adzuna sees in Canada (owner's key, `Kairos --adzuna-probe`, 2026-10-23)

| Search (`/jobs/ca/search`) | Matches | Kairos fetches today |
|---|---|---|
| `title_only=software developer`, 7 days | 388 | 50 (page 1) |
| `title_only=software engineer`, 7 days | 539 | 50 |
| `title_only=developer`, 7 days | 1,517 (first page all sales/business development) | 50 |
| `category=it-jobs`, 7 days | 6,367 | — |
| `category=it-jobs`, 1 day | 1,356 | — |
| `category=it-jobs`, `what_or=developer engineer programmer`, 7 days | 5,248 | — |
| `category=it-jobs`, `where=Halifax`, 30 days | 57 | — |

- `results_per_page=100` still returns 50: **50 is the cap**.
- `description` is exactly 500 characters. Fields: `adref`, `category`, `company`, `created`,
  `description`, `id`, `latitude`, `location` (`area` hierarchy, `display_name`), `longitude`,
  `redirect_url`, `salary_is_predicted`, `salary_max`, `salary_min`, `title`.
- Categories for `ca` include `it-jobs`, `engineering-jobs`, `graduate-jobs`.
- So Kairos sees about a tenth of Canada's developer postings on Adzuna, and loses a third of
  its search slots to "Development" noise.

## Others

| Source | Access | Full text? | Free use | Canada | Terms that matter | Verdict |
|---|---|---|---|---|---|---|
| **Himalayas** (himalayas.app/api) | `GET /jobs/api`, `/jobs/api/search?country=…`; free key | yes (`description` is "the full HTML") | 60/min, 10,000/day with a key | `country` filter; remote jobs only | link to Himalayas, use `applicationLink` as is, show only in apps you operate, remove expired jobs | **Good optional source** for remote roles open to Canada |
| **Remotive** (github.com/remotive-io/remote-jobs-api) | `GET remotive.com/api/remote-jobs?category=&search=` | yes | ~4 calls a day; >2 a minute is blocked | remote, mostly worldwide or US | link back and name Remotive; 24 h delay; don't resubmit jobs elsewhere | Optional, low volume |
| **The Muse** (themuse.com/developers/api/v2) | `GET /api/public/jobs?page=&category=&level=&location=` | `contents` (not confirmed) | 500/h, 3,600/h with a key | lists Canadian cities | terms page; registration "beyond testing" | Optional; mostly US companies |
| **JSearch** (OpenWeb Ninja, RapidAPI) | key; `/search`, `/job-details` | yes, per third-party write-ups | ~100–200 requests a month free; $25 for 10,000 | yes | it reads Google for Jobs, which itself aggregates LinkedIn, Indeed, Glassdoor | **Owner's decision**: broad, but it gets there by querying Google |
| **SerpApi Google Jobs** | key | apply links; description per result | 250 searches a month free; $25 for 1,000 | yes | same as JSearch: automated Google queries, under SerpApi's own legal cover | Owner's decision |
| **Jooble** | key on request, for site operators | snippet, links through Jooble | per key | yes | meant for webmasters showing results on their sites | Skip: snippets, and not meant for personal apps |
| **Talent.com** (formerly Neuvoo, Canadian) | publisher XML/API, paid per click | — | publisher program only | yes | for job boards that monetize clicks | Skip |
| **Indeed Publisher API** | retired (2023–2024); no self-serve replacement | — | — | — | Indeed's terms forbid automated access | Not available |
| **LinkedIn Jobs** | partner programs only | — | — | — | terms forbid automated access | Not available |
| **Google Programmable Search JSON API** | closed to new customers; ends 2027-01-01; full-web search dropped | — | 100 queries a day while it lasts | — | — | Not available for new projects |
| **Brave Search API** | key; about $5 per 1,000 queries; free credit unclear in 2026 | — | maybe ~1,000 a month in credit | — | storage rights limited | Possible for discovery only; not needed (05) |
| **HN "Who is hiring"** | Algolia HN API, free | yes (comment text) | per-IP hourly limit | some Canadian and remote posts | — | Optional; unstructured monthly thread |

## What this means for Kairos

1. Adzuna stays the main cross-company search, rebuilt (pagination, better queries, budget).
2. Himalayas is the cleanest add: full text, a country filter, a generous free key. Remotive
   is a small extra. Both only cover remote work.
3. JSearch and SerpApi are the only legal-for-the-user ways to reach jobs that live on
   LinkedIn, Indeed or Workday; they cost money past a small free tier and depend on a third
   party querying Google. Off by default; the owner decides.
4. Everything else is closed, retired, or meant for job boards that resell clicks.
