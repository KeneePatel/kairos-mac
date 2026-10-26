# ADR-016: Applied is a list; the board holds only interviews

## Status
Accepted 2026-10-26. The owner asked for applied jobs on a separate page and left the decision
to research. Changes T45's single Applications board.

## Date
2026-10-26

## Context
T45 built one board, after `Applications.dc.html`, with five columns: Applied, Screen, Interview,
Offer and Closed. After two days of real use the owner had 36 applications, all in Applied. The
column of cards made the window's minimum height 3,409 points, and the board scrolled only
sideways, so the list ran off the screen and couldn't be scrolled. Research
(`docs/research/application-tracking.md`) found that at volume well over 90% of applications
never move past Applied: in one person's log of 1,085, 44.5% got no reply and about 1% reached an
interview, and replies after two weeks are rare. Trackers built for volume (Simplify, Teal) add a
sortable list with search and an archive beside their board. Kanban keeps boards for work in
progress and leaves queues and archives off them.

## Decision
- **Applied** (new sidebar page, after Resumes): a native `Table` of every application. Columns:
  company, role, applied, status (icon and word), last change, follow-up and where you applied.
  - Sort by any column; newest applied first by default.
  - Search for company or role.
  - Scopes: Waiting, In progress, Closed, All.
  - Double-click or Return opens the application page.
  - The context menu moves every selected row to a status, or opens the job or the posting.
- **Interviews** (the board, renamed from Applications): only Screen, Interview and Offer. It
  scrolls both ways, so a long column never sets the window's height. Closed applications are in
  Applied under Closed.
- **Silence:** when applications have waited 30 days or more at Applied, Applied offers "Close
  silent…", which moves them to No reply after a confirmation. Kairos never closes them on its own.
- The application page, its Move to menu, follow-ups and notes are unchanged. No schema change.

## Alternatives considered
- One page with a Board/List switch (Huntr, Simplify). The owner asked for a separate page, and
  the board is useless for the Applied queue at this volume anyway.
- Keeping all five columns and only adding vertical scrolling. That fixes the bug but leaves a
  column of hundreds of cards with no search or sort.
- Closing silent applications automatically after N days. A wrong guess hides a live
  application, so Kairos asks first.
- A 14-day silence threshold, which is what the research suggests. Thirty days leaves room for
  slow employers, and moving one back is a single click.

## Consequences
- The sidebar reads Find jobs · Review · Improve · Filtered out · Resumes · Applied · Interviews.
- `Applications.dc.html`'s Applied and Closed columns now live in Applied's table; the board
  keeps its look for the three middle columns.
- `ApplicationRepository.setStatus` takes several applications in one write.
