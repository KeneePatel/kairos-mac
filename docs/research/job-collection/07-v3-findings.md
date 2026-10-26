# What v2 yields, and what the sources say now (research, 2026-10-26)

Measured on the owner's database with two new debug reports, `Kairos --sources-report` and one live
search through `Kairos --serpapi-probe`, with every source's docs read again. The redesign built on
this: [`docs/design/job-collection-v3.md`](../../design/job-collection-v3.md); the decision: ADR-018.

## 1. The owner's database (2,353 stored jobs)

| Kind | Jobs | Snippets | Yes | Maybe | No | Filtered | Applied | Avg chars |
|---|---|---|---|---|---|---|---|---|
| Adzuna | 1,506 | 1,506 | 0 | 331 | 91 | 1,084 | 0 | 499 |
| Ashby | 225 | 0 | 16 | 8 | 9 | 192 | 17 | 5,151 |
| Greenhouse | 209 | 0 | 6 | 2 | 9 | 192 | 7 | 6,304 |
| SmartRecruiters | 154 | 0 | 0 | 0 | 10 | 144 | 0 | 6,514 |
| Himalayas | 117 | 0 | 12 | 15 | 19 | 71 | 12 | 5,190 |
| Google Jobs | 115 | 0 | 4 | 26 | 38 | 47 | 4 | 4,792 |
| Workable | 12 | 0 | 0 | 0 | 1 | 11 | 0 | 4,980 |
| BambooHR | 7 | 0 | 0 | 0 | 1 | 6 | 0 | 7,853 |
| Recruitee | 4 | 0 | 0 | 1 | 1 | 2 | 0 | 5,385 |
| Lever | 4 | 0 | 0 | 0 | 0 | 4 | 0 | 6,884 |

- **Inbox now:** 380 Maybe, of which 331 are snippets; 179 No, 91 snippets; 0 Yes (every Yes was
  applied to).
- **Links:** all 115 Google Jobs jobs link to www.google.com, because `GoogleJobsSource` keeps
  `share_link`; all 117 Himalayas jobs link to himalayas.app, though its terms want
  `applicationLink` behind Apply; board jobs link to their own pages.
- **Dates:** no Google Jobs job has a posting date: SerpApi's `detected_extensions` came back empty
  and the age ("7 days ago") sits in `extensions`.
- **Adzuna's companies:** Citigroup 98, Jobgether 43 (an aggregator), Innosystech 23 (an agency),
  TD Bank 22, Analyst Technical Solutions 21, Maarut 20, Affirm 37 (on a Greenhouse board the owner
  already watches), Zortech 17, Miratech 16, Amazon 16, "Company not listed" 14, vTech 13, Medfar
  13, Cisco 12. Of 1,506 Adzuna jobs, 1,084 failed the filters and none was applied to.
- **Snippet upgrades:** 20 companies looked up in all (the finder's cap is 20 a run, and a lookup
  is cached), 6 boards found, 73 jobs with two listings, 1 snippet filled in.
- **Boards:** catalog 794, of which 163 list a job at the owner's roles (558 jobs) and 14 ever
  produced a Yes or Maybe; the 19 the owner added: 14 with jobs, 4 with a Yes or Maybe; 5 found
  behind searches: 1 with a job.
- **Where applied jobs came from:** Ashby 17, Himalayas 12, Greenhouse 7, Google Jobs 4.

## 2. One SerpApi Google Jobs search

`q=software developer`, `location=Toronto, Ontario, Canada`, `gl=ca`, `hl=en` (one of the plan's
250; a repeat within SerpApi's cache window is free).

- Response keys: `filters`, `jobs_results`, `search_metadata`, `search_parameters`,
  `serpapi_pagination` (`next_page_token`, `next`).
- Each job: `title`, `company_name`, `location`, `via`, `description` (the whole posting: 719 to
  10,625 characters here), `extensions` ("7 days ago", "Full-time", "$65K–$75K a year"),
  `detected_extensions` (empty on every result), `apply_options` (title and link), `share_link`
  (google.com), `source_link`, `job_id`, `thumbnail`.
- **`source_link` is the page Google took the posting from**: the employer's own page when Google
  found it there (jobs.scotiabank.com/job/…, jobs.intuit.com/job/…), a board's page otherwise
  (ca.indeed.com/viewjob, ca.linkedin.com/jobs/view/…, ca.jooble.org/jdp/…, csjobs.ca/jobs/…).
- `apply_options` lists every board carrying the job, and sometimes links that belong to other
  postings (a Scotiabank job listed OceanMD and IXL links), so an option can only be trusted when
  its title names the company or the `via` site.
- `filters`: "Date posted" (Yesterday, Last 3 days) and "Job type", each an opaque `uds` token
  that embeds the query, so filtering by date costs a second search. `chips` and `ltype` are
  deprecated.
- Of the 10 results, 7 came from staffing or consulting firms (Randstad, Procom, Softline,
  TestingXperts, Burgeon, Upstaff, Quarry), 4 were senior, 1 junior.
- Plans (serpapi.com/pricing): Free 250 searches a month, Starter $25 for 1,000, Developer $75 for
  5,000; only successful searches count. The Google Jobs Listing API (per `job_id`) now returns
  ratings only; apply options moved into the Google Jobs API itself.

## 3. Other sources, checked again

| Source | Full text | Link | Terms that matter | In v3 |
|---|---|---|---|---|
| Himalayas | yes, HTML | `applicationLink` used unchanged; a visible link to Himalayas | free key optional; 60 a minute, 10,000 a day; remove expired jobs; show only in apps you operate | kept; Apply goes to `applicationLink` |
| Remotive | yes, HTML | the Remotive job URL, named as the source | at most 4 fetches a day; 24 h delay; no reposting | added, remote only |
| The Muse | yes, HTML (about 8,000 characters) | themuse.com page, not the employer's; categories unreliable | registration beyond testing | not added |
| JSearch (OpenWeb Ninja) | yes | via Google for Jobs | RapidAPI plans | not added: the same data as SerpApi |
| Active Jobs DB (Fantastic Jobs) | ATS feeds of 275,000 career sites | employer pages | from $95 a month | not added |
| Google Programmable Search | — | — | closed to new customers, ends 2027-01-01 | not available |
| Adzuna | 500-character snippet, by design | a redirect through Adzuna (a paid click) | personal job search allowed; label "Adzuna" | leads only |

## 4. What this means

1. **Links:** Google Jobs postings should keep `source_link`, and an apply option only when its
   title names the company and `source_link` is a board's page. Himalayas Apply must open
   `applicationLink`. Both need a job's apply link apart from its identity URL.
2. **Snippets:** Adzuna can never give the full posting, the upgrade path reaches one company in
   seventy, and no Adzuna job was ever applied to. Its remaining value is the company names: who
   is hiring at the owner's roles.
3. **Quality:** half of a Google Jobs page is staffing firms; the catalog's boards mostly list
   roles the filters drop. Quality is a rule before screening (agency, level, place, age), not a
   bigger net.
4. **Discovery:** every link Kairos sees that points at a board it reads (Google's `source_link`
   and apply options, Himalayas's `applicationLink`) names a company to watch, for free.
5. **The Sources page** should show the few channels and their yield, and companies only when
   they have a role for the owner.
