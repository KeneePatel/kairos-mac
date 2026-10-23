# Public ATS job board APIs (research, 2026-10-23)

Applicant tracking systems publish each customer's open jobs so the company's own careers page
can show them. These feeds are public, keyless, and carry the **full** posting. They are
Kairos's best source of complete descriptions. The catch: each one lists one company, so
Kairos needs to know which companies to ask (see 05-company-discovery.md).

## Endpoints

| ATS | List endpoint (no key) | Full text in list? | Paging | Official docs say |
|---|---|---|---|---|
| Greenhouse | `GET boards-api.greenhouse.io/v1/boards/{token}/jobs?content=true` | yes (`content`, HTML entity-encoded) | none, all jobs | "Job Board data is publicly available, so authentication is not required for any GET endpoints." `pay_transparency=true` on the single-job call adds `pay_input_ranges`. (docs.greenhouse.io/job-board.html) |
| Lever | `GET api.lever.co/v0/postings/{site}?mode=json` (EU: `api.eu.lever.co`) | yes (`description`, `lists`, `additional`, `descriptionPlain`) | `skip`, `limit` | "all job postings in the published state are publicly viewable … These jobs may be scraped by third parties." `workplaceType` is `on-site`, `remote`, `hybrid` or `unspecified`; `salaryRange` optional; `country` ISO code. (github.com/lever/postings-api) |
| Ashby | `GET api.ashbyhq.com/posting-api/job-board/{name}?includeCompensation=true` | yes (`descriptionHtml`) | none | `isListed=false` means direct link only; `workplaceType` OnSite/Remote/Hybrid; compensation with the flag. (developers.ashbyhq.com/docs/public-job-posting-api) |
| SmartRecruiters | `GET api.smartrecruiters.com/v1/companies/{id}/postings?limit=100&offset=N` | no: `GET …/postings/{postingId}` per job (`jobAd.sections`) | `limit` ≤ 100, `offset`, `totalFound` | Official docs describe the Posting API with API key or OAuth; the per-company postings list answers without one for customers whose public feed is on. Unknown ids answer 200 with an empty list. Company id is case-sensitive (`BoschGroup`). |
| Workable | `GET apply.workable.com/api/v1/widget/accounts/{slug}?details=true` | yes with `details=true` | none | No official docs for this widget feed (third-party write-ups only). `telecommuting: true` means remote. |
| Recruitee | `GET {slug}.recruitee.com/api/offers/` | yes (`description`, `requirements`) | none | Recruitee's Careers Site API, no authorization. `published_at` isn't ISO 8601. |
| Personio | `GET {slug}.jobs.personio.de/xml?language=en` (or `.com`) | yes (`jobDescriptions`, XML) | none | Public XML feed; a non-customer slug redirects (307) to personio.com. Mostly European companies. |
| BambooHR | `GET {slug}.bamboohr.com/careers/list` | no: `/careers/{id}/detail` | none | Public careers JSON; non-customers redirect (302). Locations often null. |
| Breezy HR | `GET {slug}.breezy.hr/json` | **no descriptions** | none | Lists only. |
| Teamtailor | `GET {careers domain}/jobs.rss` | yes (escaped HTML) | none | Per-site feed the customer can turn off; most use custom domains. |
| Rippling | `GET ats.rippling.com/api/v2/board/{slug}/jobs?page=N` | no: `/jobs/{id}` | 20 a page | Third-party reference only. |
| Workday | `POST {tenant}.wd{N}.myworkdayjobs.com/wday/cxs/{tenant}/{site}/jobs` | no: per-job GET | 20 a page, ~2,000 cap | **Excluded.** Undocumented, and Workday's site terms forbid "data mining, robots or similar data gathering or extraction methods" and ignoring robots.txt (workday.com/en-ca/legal/site-terms.html). Many large Canadian employers (banks, telecoms, governments) use Workday; their jobs reach Kairos only through aggregators. |

Sources besides the official docs: github.com/Mersetti/ats-job-board-apis,
conorscode.github.io/ats-api-reference, dev.to comparisons (2026). Rate limits are
undocumented on all of them: space requests per host and back off on 429.

## Gotchas Kairos must handle

- **Empty is ambiguous** on Lever, Ashby and SmartRecruiters: "not a customer" and "no open
  roles" look the same. Discovery must not conclude from one empty answer.
- **Redirects mean "not a customer"** on Personio and BambooHR: never follow them.
- **Greenhouse `content` is entity-encoded HTML** (Kairos already decodes it).
- **Lever's `on-site`**: Kairos's `LeverSource` maps `workplaceType` through
  `Workplace(rawValue:)`, whose case is `onsite`, so "on-site" postings lose their workplace.
  A bug found during this research.
- **Lever EU** companies live on `api.eu.lever.co`; Kairos only asks the global host.
- **Pay**: Greenhouse (`pay_transparency`), Lever (`salaryRange`), Ashby
  (`includeCompensation`) can give structured pay. Kairos asks for none of it; the `salary`
  column is never filled. Ontario requires pay ranges in postings from 2026-01-01 and BC
  from 2023-11-01, so Canadian postings increasingly carry them.
- **Dates**: Greenhouse `first_published` (Kairos prefers it over `updated_at`, which moves
  on every edit), Lever `createdAt` (ms), Ashby `publishedAt` (last published), Recruitee
  `published_at` (non-ISO), Rippling none in the list.

## What this means for Kairos

1. Add **SmartRecruiters, Workable, Recruitee, Personio, BambooHR, Teamtailor** readers, all
   behind the same `JobSource` protocol, each with recorded fixtures. Breezy and Rippling
   are optional (no text in the list; one extra call per job).
2. `ATSDetector` should recognise every one of these hosts from a pasted URL, and a careers
   page on the company's own domain should be checked for the ATS it embeds.
3. Fix Lever's `on-site` mapping and ask Lever's EU host when the global one has nothing.
4. Ask each ATS for pay where it offers it, and store it.
5. Workday stays out; say so in the app where a Workday careers URL is pasted.
