# Adzuna API (research, 2026-10-23)

## What it is

A job search engine with a free API key per user (developer.adzuna.com). Kairos uses it as
its one cross-company search source (tier B, ADR-005).

## Facts, with sources

| Fact | Source |
|---|---|
| "Please note we currently only provide a snipped of the job description in the response." The API never returns the full text. | developer.adzuna.com/docs/search |
| Default limits: 25 hits a minute, 250 a day, 1,000 a week, 2,500 a month; raised for commercial partners on request. The account page shows the plan in force. | developer.adzuna.com/docs/terms_of_service; adzuna-sdk README |
| Allowed: "Personal job search", publishing ad listings, salary estimates, personal and academic research. Revenue-generating use needs a licence. | terms of service |
| Each displayed advert must be labelled "Adzuna", at least 116 × 23 px, linked to Adzuna (Kairos shows "Jobs by Adzuna"). | terms of service |
| On termination, all Adzuna data must be removed. No stated retention period otherwise. | terms of service |
| The terms say nothing about following `redirect_url`. It routes through Adzuna to the advert (paid clicks for advertisers). | terms; third-party guides |
| Result fields: `id`, `title`, `description` (snippet), `created`, `redirect_url`, `company.display_name`, `location.area[]` and `display_name`, `category.label/tag`, `salary_min/max`, `salary_is_predicted`, `contract_type`, `contract_time`, `latitude`, `longitude`. | docs/search examples |
| Search parameters documented in examples: `what`, `what_exclude`, `where`, `sort_by`, `salary_min`, `full_time`, `permanent`, `results_per_page`; the page number is the path segment (`/search/1`). The interactive reference lists more (`what_and`, `what_phrase`, `what_or`, `title_only`, `category`, `max_days_old`, `distance`, `location0…`). | docs/search; activedocs |
| The search response carries `count`, the total number of matches, so coverage can be measured. | docs/search examples |

## What this means for Kairos

1. **Snippets are permanent through this API.** Kairos keeps its rule of never fetching the
   advert link automatically: it costs advertisers a paid click, and the landing page is the
   advertiser's site, whose terms vary. The full text has to come from somewhere else (see
   02 and 05): the same job on the company's public ATS board.
2. **The free budget is about 80 searches a day averaged over a month** (2,500 / 30). Today
   Kairos spends 3 a run. A planned set of queries can afford far more coverage, as long as
   it tracks the monthly budget, not just the daily one.
3. **Pagination is the main coverage lever.** Page 1 of 50 results, sorted by date, misses
   everything past the 50th newest. `count` says how many there are; Kairos should page until
   it reaches jobs it already knows, or the posted-within limit, or a per-run page budget.
4. **Query precision.** `title_only=Developer` matched "Business Development Manager" (263
   jobs dropped by the title filter on 2026-10-23). Better: `what_phrase` or `title_only` with
   full phrases ("software developer"), `what_or` for variants, `what_exclude` for known noise
   ("business development", "sales"), and `category=it-jobs`.
5. **Company names from Adzuna are leads.** Each result names a company. Looking that company
   up on public ATS boards (02) can find the full posting, which upgrades the snippet and
   adds the company to the watchlist.
6. Geocoding quirks: Adzuna places jobs at neighbourhoods and landmarks ("Regent Park, City of
   Toronto", "CN Tower"). `location.area[]` holds the hierarchy (country, province, city), and
   `latitude`/`longitude` are there too; Kairos should parse `area` rather than `display_name`.

## Open questions (to check with the owner's key, a few calls)

- The real `count` for Canada developer searches over 7 days, to size pagination.
- The maximum `results_per_page` (50 is the commonly cited cap; not confirmed in the docs).
- Whether `category=it-jobs` exists for `ca` (`/jobs/ca/categories`).
