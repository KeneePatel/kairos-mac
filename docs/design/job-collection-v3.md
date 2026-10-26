# Job collection v3: full postings only, correct links, quality first

Status: **approved 2026-10-26** ("Approve, build C1 to C5"); built as slices C1–C5 in `tasks/todo.md`. Research:
[`docs/research/job-collection/07-v3-findings.md`](../research/job-collection/07-v3-findings.md).
Decision record: ADR-018. v2's design stays in [`job-collection.md`](job-collection.md) for what it
built; this document says what changes.

## The owner's four decisions (2026-10-26)

1. **Snippets never become jobs.** Adzuna finds companies only. "Needs a full read" leaves the Inbox.
2. **Google Jobs on SerpApi's free plan:** about 8 searches a day, each role and place in turn.
3. **Places:** Toronto, Vancouver, Montreal, Ottawa, Calgary, Waterloo, Halifax, and remote in
   Canada. Board jobs anywhere in Canada still count.
4. **Sources page:** the channels first, then one companies list.

## What's wrong today, in the owner's words and numbers

| Complaint | What the data says | Cause |
|---|---|---|
| Google Jobs links open Google, not the job | 115 of 115 link to www.google.com | `GoogleJobsSource` keeps `share_link`; SerpApi's `source_link` and `apply_options` are ignored |
| Adzuna jobs are snippets, often poor | 1,506 of 2,353 stored jobs; 331 of the 380 Maybe in the Inbox; 0 ever applied to; 1,084 failed the filters | Adzuna's API returns 500 characters by design; the upgrade path reaches 20 companies in all |
| Adding sources and the catalog feel like two different things | 821 rows on Sources: 794 from the catalog, 163 with a role for you, 14 ever with a Yes or Maybe | the catalog's boards are shown as sources, whatever they list |
| Not enough real jobs | Google Jobs: 12 searches a week at country level, undated; Himalayas links to itself; boards found behind links: none | one query per role for "Canada"; no discovery from links |

## Goals

1. **Full posting, every time.** A job exists in Kairos only when a source gave the whole text.
2. **The right link, every time.** Open posting opens the page where the posting lives: the
   employer's own page or board when known, a job board's page otherwise, never a search page.
3. **Quality before quantity.** Employers' postings at your level, in your places, recent.
   Staffing agencies and aggregators are filtered by default, copies are collapsed, and every job
   says where it was seen and when.
4. **More of the real ones.** Google Jobs per place; every link that points at a board Kairos can
   read adds that company; Remotive added; Adzuna's company names looked up, all of them over time.
5. **Within the rules**, unchanged: public APIs and feeds, polite rates, no advert clicks, no
   requests to hosts whose terms forbid them (Workday, Indeed, LinkedIn, Glassdoor, Job Bank).

## Where jobs come from (v3)

| Channel | Role | Full text | The link Kairos keeps | Finds companies |
|---|---|---|---|---|
| **Company boards** (Greenhouse, Lever, Ashby, SmartRecruiters, Workable, Recruitee, Personio, BambooHR, Teamtailor) | the backbone: every open job of a company Kairos watches | yes | the board's job page | — |
| **Google Jobs** (SerpApi, free plan) | the long tail: employers on Workday, iCIMS, SuccessFactors and job boards Kairos can't read | yes (SerpApi's `description`) | `source_link`, the page Google took it from; the employer's apply option when `source_link` is a job board's page and the option names the company | from `source_link` and apply options that point at a board Kairos reads |
| **Himalayas** | remote roles open to Canada | yes | `applicationLink`, unchanged, with a credit link to Himalayas | from `applicationLink` |
| **Remotive** (new) | remote roles | yes | the Remotive job page, named as the source (its terms) | — |
| **Adzuna** | leads: which companies post at your roles, and how many postings Kairos can't read | — | none kept | names looked up in the catalog, then probed on public boards |

The board catalog stays as it is in the fetch (every board with jobs in your countries, checked
quietly, resting three days when it has nothing for you). It stops being something you see.

## Rules

### Links

- A job keeps two addresses: `canonical_url`, its identity (unchanged, hashed into `job.id`),
  and a new **`apply_url`**, where Open posting goes. A board's job: the same page. Google Jobs:
  `source_link`, replaced by an apply option only when `source_link`'s host is a job board
  (Indeed, LinkedIn, Glassdoor, ZipRecruiter, Jooble, Talent.com, SimplyHired, Workopolis, Eluta,
  Jobrapido, BeBee, Trabajo, JobLeads, Ladders, Startup Jobs, Csjobs, CareerBeacon) **and** the
  option's title names the company or the `via` site. Never `share_link`. Himalayas:
  `applicationLink`. Remotive: its own page.
- Every job records **`via`**: the site the posting was taken from, shown in the pane ("Posted on
  Scotiabank's careers site · seen on Google Jobs 3 days ago").
- Jobs stored with a google.com link are fixed by the next fetch: the same posting comes back
  with its `source_link`, the ledger matches it to the stored job (company, title, place) and the
  new listing becomes primary. The job keeps its verdict and analysis.
- Kairos doesn't request employer pages to check links (their terms vary; Workday's forbid it). A
  board verifies its own jobs; Himalayas has a check endpoint; a Google Jobs listing closes when
  no search has returned it for 30 days, and the pane shows when it was last seen.

### Full text

- Only sources that return whole postings create jobs. Adzuna's answers are recorded as
  **leads** (company, title, place, date; local, kept 30 days), never as jobs or listings.
- Existing snippet-only jobs (1,506) are archived at the migration with a job event ("snippet
  only; Kairos keeps whole postings now"). A saved, built or applied snippet job stays (there is
  none today).
- The verdict rule `snippet_only`, the Inbox group "Needs a full read", `isSnippet` and the
  snippet note go.

### Quality

- **Staffing agencies and aggregators** fail a new prefilter rule, "Staffing agency", when the
  company name is on the agency list (Randstad, Procom, Hays, Robert Half, TEKsystems, Insight
  Global, Kforce, Akkodis, Experis, Altis, S.i. Systems, Ignite, Cleo, Maarut, Innosystech, vTech,
  Zortech, Teckhorizon, Softline, Upstaff, Jobgether, Lensa, Jobot, and the catalog's aggregator
  list), matches `agency|staffing|recruit|consultants?` with "our client" in the text, or the
  posting came via a job board and names no employer. Settings, Search gains "Show staffing-agency
  postings" (off). Filtered out shows the reason with Bring back, as for any rule.
- **Level, place, age**: the existing seniority, location and posting-age rules, with the new
  Places list (Settings, Search: cities and remote) feeding the location rule's regions.
- **Copies**: the ledger's matching as today; a Google Jobs posting whose `source_link` is a
  board's page is the same listing as the board's (same canonical URL), so the board's copy wins.
- **Posting dates** for Google Jobs come from `extensions` ("7 days ago"); the "Posted" limit
  applies; undated postings are kept, as everywhere.

### Discovery of companies

- **From links:** `ATSDetector.detect` runs on every Google Jobs `source_link` and apply option
  and every Himalayas `applicationLink`. A board found is added as a source (origin "found via
  Google Jobs" or "found via Himalayas") and read in the same fetch, so the company's other
  postings arrive in full.
- **From leads:** every company behind an Adzuna lead at your roles is looked up, over time: the
  catalog by name, then `BoardProbe` (two slugs on six boards), up to 60 companies a fetch, each
  result cached 30 days, agencies and aggregators skipped. A board found: origin "found via
  Adzuna".
- Discovered and catalog boards appear in the companies list only once they have an open role for
  you; you can mute any company.

### Google Jobs plan (free plan)

- **Pairs:** one query per role family you look for, two for software development ("software
  developer", "software engineer"; "devops engineer"; "data engineer", "machine learning
  engineer"; "qa engineer"), times your places: a city is `location=City, Province, Canada`;
  remote is `q=<phrase> remote` with `location=Canada`. About 40 pairs.
- **Rotation:** 8 searches a fetch day, the pairs least recently searched first, so every pair is
  refreshed about every 5 days; page 1 only (10 results); no date filter (it costs a second
  search); results already stored are matched by `job_id` and `source_link`.
- **Budget:** 240 a month, 8 a day, counted in the fetch log and shown on the channel's page with
  "every role and place about every 5 days". The Starter plan (1,000) would make it daily; the
  owner decides later.

### Data (migration 015)

- `job`: `apply_url TEXT`, `via TEXT`.
- `lead` (local, not synced): `id`, `source_id`, `company`, `title`, `location`, `posted_at`,
  `first_seen_at`, `last_seen_at`; trimmed after 30 days.
- The migration archives open snippet-only jobs with a job event and leaves everything else.
- `SourceKind.remotive`; Remotive runs at most 4 times a day (its terms).

## What you'll see

- **Inbox:** two groups, Decide and No from the AI. The pane's header says where the posting lives
  and where Kairos saw it; Open posting (O) goes there.
- **Sources:** a page of channels, each with its yield this week and one line of settings:
  Company boards (163 hiring for you · 19 you added · 42 found · checked 12:39), Google Jobs (8
  searches a day · 184 of 250 left this month · every role and place about every 5 days),
  Himalayas, Remotive, Adzuna leads (1,200 postings at 600 companies · 31 boards found · "Jobs by
  Adzuna"). Company boards opens the companies list, filtered Hiring for you · Watching · Found by
  Kairos · Muted · All, with search, Add company, and the company pane beside it as today. Google
  Jobs opens its page: the key, the places, the plan and this week's results; the other channels
  likewise.
- **Settings, Search:** Places (cities, remote) under Where; "Show staffing-agency postings" under
  Limits.
- **Filtered out:** the new reason "Staffing agency".
- **Reports:** `--sources-report` and `--serpapi-probe` stay as debug commands; the coverage report
  counts leads and boards found.

## Phases (each its own PR with the full gate)

| # | Phase | Delivers | Size |
|---|---|---|---|
| C1 | Google Jobs done right | `apply_url` and `via` (migration 015); `source_link` and the apply-option rule; dates from `extensions`; boards found from Google's links; a recorded SerpApi fixture; the pane's "posted on · seen on" line; stored google.com links fixed by the next fetch | S |
| C2 | Full postings only | Adzuna answers become leads; lead-based company lookup, 60 a fetch; snippet-only jobs archived; `snippet_only`, "Needs a full read" and the snippet note removed; Himalayas Apply on `applicationLink` with its credit and boards found from it; Remotive source with its credit | M |
| C3 | Quality and the plan | the "Staffing agency" rule and its setting; Places in Settings, Search; the Google Jobs rotation and budget; Filtered out's new reason | M |
| C4 | Sources page v3 | channels page with yields; companies list with its filters; the Google Jobs, Himalayas, Remotive and Adzuna leads pages; the catalog invisible until it hires for you | M |
| C5 | Docs | SPEC §5.2 and §5.4; ADR-018 accepted; research README; memory | S |

Every phase: tests first with recorded fixtures (no network in tests), the migration tested on a
copy of the owner's database, `--sources-report` before and after, snapshots and the layout probe
for every changed screen, one live run against the real sources.

## Done when (measured with `--sources-report`)

- No open job is a snippet; no job links to google.com; at least 90% of Google Jobs jobs are dated.
- The Inbox has two groups; its Maybe group is no longer two-thirds Adzuna.
- Sources shows five channels; the companies list shows, by default, only boards hiring for you.
- The owner's next week of applications comes from jobs whose posting opened on the first click.
