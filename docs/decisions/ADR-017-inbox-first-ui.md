# ADR-017: The Mac app is organised around an inbox of jobs to decide

## Status
Accepted 2026-10-26: the owner approved the v2 design draft ("Approve, build it") and the eight slices followed (`tasks/todo.md`, UI v2).

## Date
2026-10-26

## Context
After two days of real use (36 applications, 2,353 jobs) the owner asked for the whole UI to be reimagined. The audit (`docs/design/ui-v2/DESIGN_BRIEF.md`) found that Review's default tab was empty because every Yes job had been applied to, that the working set was 383 Maybes of which 283 were Adzuna snippets, that deciding on a job took a page change and icon-only buttons with no shortcuts, that ten sidebar sections had grown task by task, and that fetching, screening and building reported progress in different places. The owner chose, in an interview: an inbox of jobs to decide as the home, the job beside the list, keyboard-first decisions with visible keys, and a calmer look drafted for approval before code (Things-like, compact rows).

## Decision
- **Inbox** replaces Review as the home: every open job without a decision, best match first, Canada first, in three groups (Decide, Needs a full read, No from the AI). Verdict is a label and a filter, not a tab.
- **Three columns:** sidebar, list, pane. The selected job (or build, application, source) shows beside its list; Return opens it full width. The full-page job screen and the side inspector of P3 both go.
- **One key per decision:** B build, S save, X skip, O open posting, A mark applied, V verdict, R re-evaluate, ↑↓ move, ⌘Z undo. Keys show on the buttons and in the Job menu.
- **Saved and Skipped** become places (the `shortlisted` and `skipped` states), so a decision always moves a job somewhere visible and reversible.
- **Find new jobs** is an action (⌘R) and the sidebar footer is the one status line; the Find jobs page splits into Sources, Filtered out and that footer.
- **Settings** is a page with a left list; the menu bar item is designed with v2 and built as a slice.
- **Visual v2:** `tokens.json` v2 (warm neutrals, window/surface/raised/sunken grounds, a page title style, 36 pt rows, key caps), the same generator and checks. Verdict rules, the logo and the accent stay.

## Alternatives considered
- Keep the verdict tabs and polish each list: leaves the empty Yes tab and the snippet-swamped Maybe list as the daily experience.
- A dashboard home: adds a screen between the owner and the jobs; the status footer and badges carry the same information.
- A narrow inspector as the 2026-10-18 mockups: the owner removed it in P3 because requirements and evidence didn't fit; a pane of two thirds of the window does.
- Mouse-first with large buttons: fifteen to twenty-five decisions a day reward one key each; the buttons stay for the mouse.
- Keeping the look and only restructuring: the owner asked for a refresh; the token pipeline makes it cheap to carry.

## Consequences
- `AppSection` becomes Inbox · Saved · Resumes · Applied · Interviews · Improve · Filtered out · Skipped · Master resume · Sources · Settings; Find jobs and Activity go.
- `JobState.shortlisted` gets UI; `skip` becomes reversible from Skipped.
- A `Job` menu and `View` menu carry every shortcut; single-key shortcuts act only while a list or pane has focus.
- `design/kairos/` gets v2 tokens, a v2 README and v2 screens exported from the design canvas; v1 files stay in `design/kairos/v1/` for the record.
- SPEC §4's `app-mac` row and §5.2's screens text are rewritten to match; ADR-016 stands (Applied is a table, Interviews a board).
- Built in slices behind PRs, each gated: shell and status, Inbox and job pane, Resumes, Applied and Interviews, Sources and Settings, Master resume, reports, menu bar.
