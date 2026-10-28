# Design brief: Kairos UI v2

**Status:** draft for the owner's review, 2026-10-26. Interview answers are recorded under Decisions.
**Scope:** every screen of the Mac app, the menu bar item and the visual language (`design/kairos/tokens.json` v2).
**Downstream:** `INFORMATION_ARCHITECTURE.md` (structure), the "Kairos v2" design system and design canvas on claude.ai (visuals), ADR-017 (decision), `tasks/todo.md` (build slices).

## Problem

Kairos finds hundreds of jobs a day and screens them well, but working through them is slow and the app doesn't say what's going on. After two days of real use:

- The first thing you see, Review's Yes tab, is empty, because you've already applied to every Yes job. The 383 Maybes are what you actually work through, and 283 of them are Maybe only because Adzuna gave a snippet, so the list you live in mixes "decide now" with "go read the posting first".
- Deciding on a job takes a row click, a page that replaces the list, a toolbar of icon-only buttons (hand, thumbs-down, paper plane), and Back. Nothing has a keyboard shortcut. Fifteen to twenty-five times a day.
- Ten sidebar sections grew task by task: three are reports or placeholders, and Find jobs is a run button, a status board and an 821-row company table on one page.
- Every screen explains itself in sentences, and every costly action opens a dialog with a paragraph.
- Fetching, screening and building happen somewhere; you learn about them from a banner on one screen, a subtitle on another, or a dialog.

## Solution

Kairos opens to an **Inbox**: the jobs waiting for your decision, best match first, Canada first, with the job itself beside the list. You move with the arrow keys and decide with one key: **B**uild, **S**ave, s**k**ip (X), **O**pen the posting. A decision moves the job on and the next one is already selected. Snippets that need a full read sit in their own group. The sidebar's footer always says what Kairos is doing (finding, screening, building, or when it last checked) with one Stop. Everything else is one of five things you track (Saved, Resumes, Applied, Interviews) or setup, and reports live under Reports.

The look is calm: warm neutrals, big quiet titles, compact rows, hairlines instead of boxes, colour only where it means something (the accent for the one primary action and the selection, green, amber and grey for verdicts).

## Experience principles

1. **One list, one decision at a time** over sorting jobs into tabs. The Inbox ranks; you decide; the next job is selected. Verdict is a label and a filter, never a place.
2. **Say what's happening, not why it works.** Status is one line in the sidebar, cost is a number on the button, provenance is a tooltip. No sentence explains the mechanism on a working screen.
3. **Quiet surfaces, loud decisions.** Rows, cards and panels recede (warm neutrals, hairlines, no fills) so that the verdict, the match and the primary button are the only things with colour.

## Aesthetic direction

- **Philosophy:** paper and ink. A page you read, not a dashboard you monitor. Things 3 is the reference for calm: generous margins around content, compact lines inside it, large bold titles, no decoration.
- **Tone:** calm, assured, plain-spoken. Kairos never sounds busy.
- **Reference points:** Things 3 (space, titles, restraint), Apple Mail and Notes (three-column reading, system materials), Linear (keyboard model, hover-revealed controls, shortcut hints).
- **Anti-references:** admin dashboards (KPI tiles, charts everywhere), Kanban-first trackers, AI-product chrome (gradients, purple, sparkles), the current app's rounded grey boxes on every section.
- **Platform:** macOS 26. Liquid Glass stays on navigation only (sidebar, toolbar, menu bar popover). Content panels are solid.

## Decisions from the interview (2026-10-26)

| Question | Your answer |
| --- | --- |
| What opens each day | An inbox of jobs to decide, best first; verdict as label and filter |
| Reading a job | Beside the list, about two thirds of the window; full page one key away |
| Deciding | Keyboard first with the keys shown on the buttons; the mouse works everywhere |
| Visual scope | Rebuild the structure and refresh the look, drafted for approval before code |
| Feel | Things-like calm |
| Density | Compact rows (about 36 pt), roughly 20 jobs on a laptop screen |
| Applying | Build, then apply on the company's site: Build is the inbox's key action; Open posting and Mark applied sit together on the resume |

Confirmed intent: open to an inbox beside the job, decide with one key, always see what Kairos is doing, fewer places each obvious, a refreshed look approved before code. Out of scope: the phone web app, accounts and sync, new job sources, anything that submits applications.

## Existing patterns

- **Tokens:** `design/kairos/tokens.json` (v1) generates the Asset Catalog colour sets and `DesignTokens.swift`; `scripts/check-design.sh` forbids hard-coded colours. v2 replaces the values and adds tokens (window, raised and sunken surfaces, key-cap, hover) through the same generator.
- **Type:** SF Pro on macOS text styles; v2 adds a page title (24/30 bold) and a 36 pt compact row.
- **Components kept:** `VerdictPill`, `RequirementRow`, `Meter`, `MarkdownView`, `ResumeStatus`, the master resume editor's sections and sheets, the PDF preview, the board card. Each is restyled, not rewritten.
- **Navigation:** `NavigationSplitView` grows a third column; `.inspector` stays for Master resume and the resume page.

## Component inventory

| Component | Status | Notes |
| --- | --- | --- |
| Sidebar with sections, badges and a status footer | Modify | Footer is new: one line, a 6 pt meter, Stop |
| Column title (big title, count line) | New | Replaces `navigationTitle` and subtitle on list screens |
| Job row (compact) | New | Verdict glyph and word, title, company · place, match, resume dot |
| List group header ("Needs a full read · 283") | New | Caption, count, collapsible for "No from the AI" |
| Job pane (header, actions, verdict card, requirements, posting) | New | Replaces `JobScreen` as a pane; the same view fills the window on Return |
| Action button with key cap | New | Primary and plain variants; the key shown at the trailing edge |
| Key cap | New | 11 pt caption in a 16 pt rounded square, hairline border |
| Verdict pill | Modify | 20 pt, tinted capsule, icon and word |
| Match score | Modify | Tabular, 17 pt in rows and 24 pt on the pane |
| Requirement row | Modify | Tighter: glyph, text, evidence on one meta line |
| Status card (verdict, match, reason) | Modify | Hairline card instead of a grey fill |
| Empty state | Modify | Title, one line, one button, no icon |
| Snippet callout | New | "Only a snippet from Adzuna" with Open posting |
| Resume page (steps, PDF, trace) | Modify | Three panes stay; calmer headers; actions carry key caps |
| Application table and application pane | Modify | Pane replaces the full-page application screen |
| Board column and card | Modify | Hairline cards, calm headers |
| Settings page (left list, form) | New | Replaces the segmented tabs |
| Form section (title, caption, controls) | Modify | Hairline-separated sections, 640 pt max width |
| Menu bar popover | New | Not built yet (SPEC R2); designed here |
| Command palette | Deferred | Not in v2; the menu bar and shortcuts cover it |

## Key interactions

- **Moving:** ↑ ↓ (and J K) move the selection in any list; the pane follows. Return opens the job full width; Esc returns.
- **Deciding (Inbox and Saved):** B queues a build and shows its cost on the button ("Build · 3 calls"); S saves or unsaves; X skips; O opens the posting in the browser; A marks applied (asks once when there's no build); V opens the verdict menu; R re-evaluates. After B, S or X the next job is selected. ⌘Z undoes the last S or X.
- **Status:** the sidebar footer shows "Finding jobs · 212 of 821 boards", "Screening 40 of 120 · 3 Yes so far", "Building 2 resumes", or "Checked 3:17 AM · next 1:00 PM". Stop is there while something runs. Nothing else in the app announces progress, except the resume page for its own build.
- **Cost:** a button that spends AI calls says so in its label ("Re-screen · about 40 calls"); the confirmation is the button itself in a menu, not a dialog with a paragraph. Dialogs remain for destructive actions only (delete, close silent).
- **Find new jobs:** ⌘R or the toolbar button, from anywhere. New jobs appear in the Inbox as they're screened, selected job untouched.
- **Snippets:** the "Needs a full read" group's rows carry Open posting as their first action; once the job also appears on a board with the full text, it moves into Decide on its own.
- **Selection and hover:** row controls (Open, Save) appear on hover, with the keys in their tooltips.

## Window behaviour

- Minimum 960 × 600. Default 1280 × 820. The sidebar collapses first; the list column is 320 to 420 pt; the pane takes the rest, never under 480 pt.
- The layout probe (`Kairos --layout-probe`) must pass on every screen at the minimum size.
- Dark and light are both first-class; every token has both values and every text pair passes 4.5:1.

## Accessibility

- Contrast 4.5:1 for all text in both themes (checked by script against `tokens.json`); 3:1 for control outlines and key caps.
- Every verdict and status shows colour, icon and word. "No" rows dim with `ink-dimmed`, never opacity.
- Every action reachable from the keyboard with a visible shortcut; focus rings are the system's.
- Accessibility labels on every icon-only control; the key caps are hidden from VoiceOver (the shortcut is in the control).
- Text follows the user's text size (text styles, not fixed sizes, except the match score).

## Out of scope

- The phone web app and the menu bar's sync status (R4).
- Accounts, sign-in, sync (R3).
- New job sources or scrapers; the Adzuna snippet limit itself.
- A command palette, custom themes, icon packs.
- Automatic application submission.
