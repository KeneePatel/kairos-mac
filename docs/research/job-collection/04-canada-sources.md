# Canadian job sources (research, 2026-10-23)

The owner looks for work in Canada only (work permit; Halifax, Atlantic time). Which
Canadian sources can a personal app read?

| Source | Access for a personal app | Notes | Source |
|---|---|---|---|
| **Job Bank** (jobbank.gc.ca) | No. An XML feed exists for partner job boards only: active Canadian Business Number, a board advertising "a considerable number" of Canadian postings monthly, free for job seekers, NOC titles on every posting. Its terms forbid "any script, robot, spider, Web crawler, screen scraper". Open data is monthly CSV, historical. | Third-party "Job Bank scrapers" on Apify break the terms. | jobbank.gc.ca/network; T41 note in tasks/todo.md |
| **WorkBC Job Posting API** | Unclear: a read-only API exists (job postings, regions, industries); no public sign-up found. Since 2022 BC employers post through Job Bank. | Worth an email to WorkBC if BC matters. | gov.bc.ca jobposting listing; workbc.ca employer FAQ |
| **GC Jobs** (federal public service) | No live API or feed found; only yearly open-data files of past advertisements. | | open.canada.ca "Advertisements to the Public Service" |
| **CareerBeacon** (Atlantic Canada) | No public feed or API found. | Strong for Halifax and Atlantic employers; reachable only by visiting it. | careerbeacon.com; MSVU career services |
| **Talent.com** | Publisher program (XML, API) paid per click, for job boards. | | employers.talent.com/publishers |
| **Indeed Canada, Workopolis, Glassdoor, LinkedIn** | No: retired APIs, partner-only programs, and terms that forbid automated access. Indeed CA also sits behind a Cloudflare bot check (T41). | Dropped 2026-10-22 by the owner. | tasks/todo.md T41–T43 |
| **Eluta.ca, Jobillico** | No API found. | Eluta crawls employer career sites itself. | — |
| **Getro / VC portfolio job boards** (e.g. Canadian accelerators) | Getro's API is for the network owner (bearer key, 30/min). | The companies behind them mostly use Greenhouse, Lever, Ashby: reach them there. | apis.io/providers/getro |
| **Adzuna Canada** | Yes, with a free key (01). | 6,367 IT postings in 7 days; includes jobs from Job Bank, Workday employers and agencies. | 03 |
| **Company ATS boards** | Yes, public (02). | ~16–21% of public boards list a Canadian job (05). | 05 |

## Pay transparency (helps screening)

- **British Columbia**, from 2023-11-01: every publicly advertised job must state pay, with
  a bounded range ("up to $30" doesn't qualify) (news.gov.bc.ca 2023FIN0062-001679).
- **Ontario**, from 2026-01-01: employers with 25 or more employees must include pay or a
  range (a range up to $50,000 wide unless pay exceeds $200,000) in public postings, and
  disclose AI screening (cp24.com 2026-01-05; lawtimesnews.com).
- So Canadian postings increasingly carry pay. Greenhouse, Lever and Ashby expose it as
  structured fields when asked (02).

## What this means for Kairos

Canada's own boards are closed to a personal app. Canadian coverage comes from:
1. **Adzuna `ca`**, fetched properly (it already carries Job Bank and Workday employers' jobs);
2. **public ATS boards of companies with Canadian jobs**, found systematically (05);
3. optionally **Himalayas** for remote roles open to Canada (03).
