# Information architecture: Kairos UI v2

Draft 2026-10-26, from `DESIGN_BRIEF.md`. Routes are app sections and `kairos://` links, not URLs.

## Site map

- **Inbox** `kairos://inbox` — jobs waiting for your decision (state `new`, verdict known, still posted)
  - Job pane `kairos://job/<id>` — the selected job; Return opens it full width
- **Saved** `kairos://saved` — jobs you kept for later (state `shortlisted`)
- **Resumes** `kairos://resumes` — every build, newest first; a job's resume page `kairos://resume/<build>`
- **Applied** `kairos://applied` — every application as a table (Waiting · In progress · Closed · All); application pane `kairos://application/<id>`
- **Interviews** `kairos://interviews` — the board of Screen, Interview and Offer, same application pane
- Reports
  - **Improve** `kairos://improve` — what keeps No and Maybe from Yes
  - **Filtered out** `kairos://filtered` — what your filters dropped, by reason, with Bring back
  - **Skipped** `kairos://skipped` — jobs you skipped or that closed, with Bring back
- Setup
  - **Master resume** `kairos://master-resume`
  - **Sources** `kairos://sources` — boards and companies (Yours · Catalog · All), Add
  - **Settings** `kairos://settings/<general|search|ai|account>` — also ⌘,
- **Menu bar item** — next check, what's waiting, running builds, Find new jobs, Open Kairos

Find new jobs is an action (⌘R, toolbar, menu bar), not a place. What used to be the Find jobs page splits into the sidebar footer (status), Sources (the table) and Filtered out (the counts).

## Navigation model

- **Primary:** the sidebar, five working sections then two groups. Badges: Inbox (to decide), Resumes (building), Interviews (in progress). Reports and Setup items carry no badge.
- **Secondary:** inside a section, a column of items on the left and the selected item's pane on the right (three columns in all). Scopes (Waiting · In progress · Closed) and filters live in the toolbar as menus or a segmented control, never as sidebar items.
- **Tertiary:** the pane's own sections scroll; the full-width page (Return) is the same view with room.
- **Utility:** the toolbar holds search (⌘F), filter and sort menus, and the one run action. The More menu (…) holds the rare actions: Re-screen all, Re-check filters, Close silent, Delete all jobs.
- **Keyboard:** ⌘1–⌘5 for the five working sections; ↑↓ J K move; B S X O A V R act on a job; Return opens full width; Esc goes back; ⌘Z undoes a Save or Skip; ⌘R finds new jobs; ⌘, opens Settings. Every shortcut is in the menu bar's Job and View menus and shown as a key cap on its button.
- **Status:** the sidebar footer. One line, a meter while something runs, Stop.

## Content hierarchy

### Inbox
1. The selected job's pane: title, company, actions, verdict and match — the decision happens here
2. The list: Decide (Yes and Maybe with full postings, by match, Canada first), Needs a full read (snippets), No from the AI (collapsed, dimmed)
3. The column title with counts ("247 to decide · 283 need a full read")
4. Toolbar: search, Filter (verdict, country, posted), Sort (match, newest, company), Find new jobs

### Job pane
1. Company · via board; title; location · work · posted
2. Actions: Build (primary), Save, Skip, Open posting, More
3. Verdict card: pill, match, the deciding reason; who decided as a tooltip
4. Must-haves, then Nice-to-haves: glyph, requirement, evidence
5. Where it's posted (compact) and the job's history
6. The posting, in full; for a snippet, the callout and Open posting

### Resumes
1. The resume page for the selected build: PDF with Resume · Cover letter, steps and score on the left, trace on the right
2. Actions: Mark applied (primary until applied), Open posting, Save PDF, Build again (Full · Lite), Reveal
3. The list: builds grouped Today · Yesterday · Earlier with status, score and the job

### Applied
1. The table: company, role, applied, status (icon and word), last change, follow-up, via; sortable; search
2. The application pane: status with Move to, follow-up, timeline, notes, Open job, Open posting
3. Scope: Waiting · In progress · Closed · All; Close silent… in More

### Interviews
1. Three columns with calm headers and hairline cards; a card selects the application pane
2. Follow-ups due show on the card, amber with a bell and words

### Improve, Filtered out, Skipped
1. A list of fixes or reasons on the left with counts; the detail on the right, as today
2. Bring back on each job in Filtered out and Skipped; Change in Settings as a link

### Master resume
1. Readiness in the inspector: ready, or what's missing
2. Contact, About you, Experience, Education, Skills, more sections, each with Add

### Sources
1. The table: company, board, open roles, last checked, status; Yours · Catalog · All; search
2. The source pane: status and last run, its open roles for you, Pause, Remove, Change keys
3. Add menu: company board, Adzuna, Himalayas, Google Jobs

### Settings
1. Left list: General, Search, AI, Account
2. The form, 640 pt wide: sections with a title and a caption, hairline-separated

## User flows

### The morning
1. Kairos opens to Inbox; the footer says "Checked 7:58 AM · 14 new" (or runs the check if scheduled)
2. The first job is selected; its pane shows the verdict, match and reason
3. ↓ moves through Decide. For each: B (build), S (save), X (skip) or O (read the posting)
   - B: a build is queued; the row shows a small dot; the footer says "Building 1 resume"; the next job is selected
   - X: the job leaves the Inbox (Skipped); ⌘Z brings it back
4. Needs a full read: O opens the posting; after reading, B, S or X as above
5. Resumes (⌘3): for each finished build, review, Save PDF, O opens the posting to apply, A marks it applied
6. Applied holds the rest of the story

### Re-screening after a settings change
1. Settings · Search changes a limit; the footer notes "Settings changed · 412 jobs would be judged again"
2. More › Re-screen all · about 40 calls; the footer shows progress; verdicts update in place

### Adding a company
1. Sources › Add › Company board…; paste the careers page; the sheet names the board it found
2. ⌘R finds its jobs; new ones appear in Inbox as screened

### Setting up AI
1. Settings · AI: Add provider, paste the key, Test; the recommended setup is one click
2. The footer and the Inbox title say when screening waits for a key ("Add an AI key to screen 40 jobs")

## Naming conventions

| Concept | Label in UI | Notes |
| --- | --- | --- |
| Jobs waiting for your decision | Inbox | Was Review; verdict tabs go |
| Keep a job for later | Save / Saved | The `shortlisted` state, unused by the UI until now |
| Decline a job | Skip / Skipped | Was "Not for me"; reversible with Bring back |
| Snippet-only jobs | Needs a full read | The Adzuna cap, as a group not a verdict |
| The AI's reading | Verdict (Yes · Maybe · No) and Match | Unchanged |
| Tailor a resume | Build / Resumes | Unchanged |
| Record that you applied | Mark applied / Applied | Unchanged |
| Screen, Interview, Offer | Interviews | Unchanged (ADR-016) |
| Check every board | Find new jobs (⌘R) | Was the Find jobs page |
| Boards and companies | Sources | Back to the design's name |
| What your filters dropped | Filtered out | Unchanged |
| What keeps jobs from Yes | Improve | Unchanged |

## Component reuse map

| Component | Used on | Differences |
| --- | --- | --- |
| Three-column shell (sidebar · list · pane) | Inbox, Saved, Resumes, Applied, Interviews, Sources, Improve, Filtered out, Skipped | Interviews' middle column is the board; Settings' is the tab list |
| Column title | every list column | Count line differs |
| Job row | Inbox, Saved, Skipped, Filtered out | Filtered out shows the reason instead of the verdict |
| Job pane | Inbox, Saved, Skipped, Filtered out, from Applied (Open job) | Actions differ by state (Bring back instead of Skip) |
| Application pane | Applied, Interviews | Same |
| Resume page | Resumes, from a job (Resume) | Same view |
| Status footer | sidebar | Same everywhere |
| Form section | Settings, Master resume, sheets | Same |

## Content growth

- Jobs: hundreds a day. Search (⌘F), Filter and Sort in every list; "No from the AI" collapsed; retention (T46) archives old jobs; Skipped keeps what you declined until retention.
- Builds: dozens a week. Grouped by day; the list shows the latest 200 and searches the rest.
- Applications: a table, sortable, searchable; Close silent keeps Waiting honest.
- Sources: a catalog of 800+; Yours · Catalog · All plus search.

## Routes

`kairos://<section>` and `kairos://job/<id>`, `kairos://resume/<build>`, `kairos://application/<id>`, used by notifications and the menu bar item. A route selects the section and the item; it never changes data.
