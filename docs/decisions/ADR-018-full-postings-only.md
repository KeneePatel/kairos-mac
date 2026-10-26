# ADR-018: Kairos keeps only postings it can read in full, and links to where they live

## Status
Accepted 2026-10-26: the owner approved the v3 design (`docs/design/job-collection-v3.md`) as written ("Approve, build C1 to C5").

## Date
2026-10-26

## Context
After job collection v2 (ADR-015), 1,506 of the owner's 2,353 stored jobs were Adzuna snippets:
500 characters that the screener can judge as Maybe at most, 331 of the 380 Maybe jobs in the
Inbox, and none ever applied to. The path meant to fill them in from company boards reached 20
companies in all and filled in one job. Google Jobs postings, whose text is complete, linked to
Google's search page because the source kept `share_link`. Himalayas jobs linked to Himalayas
rather than the application link its terms require. The Sources page showed 821 boards, 14 of
which had ever produced a Yes or Maybe. The owner asked for full descriptions every time, correct
links, better quality and more real jobs, and for Sources to stop distinguishing "yours" from "the
catalog".

## Decision
1. **A job exists only when a source gave the whole posting.** Sources that return snippets
   (Adzuna) produce leads, not jobs: company names and counts that Kairos uses to find boards it
   can read in full. Existing snippet-only jobs are archived.
2. **Every job keeps where it lives.** `apply_url` opens the page the posting was taken from
   (Google's `source_link`, Himalayas's `applicationLink`, a board's job page), and `via` names
   the site. A search page is never a job's link.
3. **Quality is a rule before screening**: staffing agencies and aggregators are filtered by
   default, with a setting and Bring back; level, place and age rules stay; the places Kairos
   searches are a setting.
4. **Companies are discovered from links and leads**, not only from the catalog: every link that
   points at a board Kairos reads adds that company; every lead's company is looked up over time.
5. **Sources is organised by channel**, then one companies list that shows a board only once it
   has a role for you.

## Alternatives considered
- **Keep snippets in a Leads list** outside the Inbox: the owner chose to drop them; a list of
  postings Kairos can't read invites manual work the app exists to remove.
- **Follow Adzuna's redirect to read the posting**: a paid click for the advertiser on every job,
  on the advertiser's site, whose terms vary. Rejected in v2 and again here.
- **Pay for Google Jobs (SerpApi Starter) or JSearch** from the start: the free plan first; the
  channel's page shows what more would buy.
- **Request employer pages to verify links**: their terms vary and Workday's forbid it; a board
  verifies its own jobs and a search listing closes when unseen for 30 days instead.

## Consequences
- The Inbox shrinks to postings the screener can judge whole; Maybe no longer means "unread".
- Adzuna's budget shrinks to what discovery needs; its data appears only as counts, labelled.
- A migration (015) adds `apply_url` and `via`, a `lead` table, and archives snippet jobs.
- Google Jobs coverage on the free plan is about every role and place every five days; coverage
  of employers on Workday, iCIMS and job boards depends on it.
- Remotive joins with its terms (four fetches a day, its own page as the link, a 24-hour delay).
