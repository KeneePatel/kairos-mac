# Keeping track of many applications (research, 2026-10-26)

The owner applied to 36 jobs in two days through Kairos (23 on Oct 24, 13 on Oct 25). All 36
were still "Applied". The Applications board (T45, after `Applications.dc.html`) put them all in
one Applied column of cards. The column asked for a window 3,409 points tall (`Kairos
--layout-probe`), and the board scrolled only sideways, so the window grew past the screen and the
list couldn't be scrolled. The owner asked whether applied jobs belong on a board at all.

## What happens to applications at volume

- One job seeker logged 1,085 applications from January 2024 to September 2025. 44.5% got no
  reply at all, 6.2% got a positive one (a recruiter wanted to talk), and about 1% reached a first
  interview. The median wait for a positive reply was 8 days. (Mel Drews, LinkedIn post, cited on
  linkedin.com/in/leeoffill; one person's log, self-reported.)
- Careery's 2025 benchmark of 1,000+ job seekers: the median time to an interview-related email is
  6.7 days, 75% arrive by day 8–9, and after day 14 "treat silence as a soft rejection"
  (careery.pro/research/job-application-response-time-benchmarks-2025). It's self-published by a
  company that sells application services, and it counts interview emails only.
- Survale's 2025 CandE benchmark: 31% of North American candidates hadn't heard back 1–2+ months
  after applying (survale.com, 2025 candidate experience key statistics).

**So:** at Kairos's pace (around 15–25 a day), well over 90% of applications will never move past
Applied. A handful reach a screen or an interview, and those few are the ones to act on.

## How job trackers show them

| Tool | Views | Notes |
|---|---|---|
| Huntr | Board of stages (Wishlist → Applied → Interview → Offer), plus a list and a map | Stages can be renamed (help.huntr.co, Job Tracker; The Job Board) |
| Careerflow | Board of statuses; drag a card, or pick from a dropdown in the detail view | Default statuses Saved, Applied, Interviewing, Offer, Rejected (help.careerflow.ai) |
| Simplify | **Columns** (drag between stages) and **List** (status from a dropdown) | Search by company or role; filter by date, type and stage; archive one or "Archive all"; Gmail suggests status changes (help.simplify.jobs, Using the Job Tracker) |
| Teal | A grid with sortable columns, grouped by status or not | A funnel at the top filters to one stage (tealhq.helpscoutdocs.com, Job Tracker) |

The board is the common default, but the tools built for volume add a sortable list with search
and filters, and an archive.

## Boards are for work in progress

Kanban practice limits the columns where work is in progress. Backlog, Done and Archive columns
are left unlimited because work piles up there, and they're usually kept off the working board
(docs.gitscrum.com, Kanban WIP limits; magnatag.com, Kanban board columns). A job seeker's work in
progress is the screens, interviews and offers. "Applied, waiting" is a queue and "Closed" is an
archive.

## Apple's guidance

The macOS HIG recommends a table for many items with the same fields. People click a column
heading to sort by it, and click again to reverse the order. SwiftUI's `Table` shows the sort
order, and the app sorts the rows itself (developer.apple.com, Lists and tables; SwiftUI `Table`,
`TableColumn`).

## What this means for Kairos

- **Applied** is its own page: a native table of every application, newest first. It has sortable
  columns, a search for company or role, and scopes for Waiting, In progress, Closed and All. You
  can select several rows and move them together (for example to No reply), or open one.
- **Interviews** keeps the board, now only for the stages where something happens: Screen,
  Interview and Offer. It scrolls both ways and never asks for a taller window.
- **Silence:** applications still at Applied after 30 days can be closed as No reply in one step,
  after a confirmation. Thirty days is twice the two-week mark the research gives, and moving one
  back is a single click. Kairos never closes them on its own.
- The application page (status, Move to, follow-up, timeline, notes) stays as it is.
