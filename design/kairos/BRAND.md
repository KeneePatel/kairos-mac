Kairos finds jobs worth applying to and builds a tailored resume for each. Its interface is paper and ink: a page you read and act on, not a dashboard you monitor. Build every screen from these rules; take every value from `tokens.json`.

## Voice and copy

- Write to the person as "you"; Kairos is "Kairos", never "we" or "I".
- Say what happened or what to do, in one line: "247 to decide · 283 need a full read", "Checked 7:58 AM · next 1:00 PM". Never explain the mechanism on a working screen; put provenance in a tooltip ("Decided by code from the AI's reading").
- Put the cost on the control that spends it: "Re-screen · about 40 calls". No dialog with a paragraph, except for destructive actions.
- Labels are verbs for actions (Build, Save, Skip, Open posting, Mark applied) and nouns for places (Inbox, Saved, Resumes, Applied, Interviews).
- Numbers in text use tabular figures; counts over 999 take a separator.
- No emoji, no exclamation marks, no "AI-powered".

## Colour

- Grounds: `window` behind everything, `surface` for panels and lists, `surface-raised` for cards, key caps and the hover row, `surface-sunken` under the resume page and the board.
- Text: `ink` for titles and rows, `ink-2` for reading text, `ink-secondary` for meta, counts and headers. Jobs you've skipped or applied to, and No rows, use `ink-dimmed` for every text in the row; never dim with opacity.
- One accent: `accent` fills the one primary button a view allows and the selected segment; `accent-tint` fills the selected row; `accent-selection-nav` the selected sidebar item; `accent-text` colours links and plain blue buttons. Nothing else is blue.
- Verdicts: `yes` on `yes-bg`, `maybe` on `maybe-bg`, `no` on `no-bg`, always as a pill with the icon and the word. The same three colours mark requirement rows (Shown, Partly shown, Not shown uses `ink-secondary`). `maybe` also marks "a run stopped early" and "a follow-up due".
- `error` with an icon and words for a failed build, an unreachable board, a field error; `error-bg` only when the line needs a ground.
- Lines: `separator` between panes and sections, `separator-row` between rows, `outline` on fields, switches and key caps. Cards are a hairline of `separator` on `surface-raised`, never a filled grey box with no edge.
- Every text pair above passes 4.5:1 in both themes; every outline 3:1. Keep it that way when adding a pair: check both themes.

## Type

- SF Pro through the `sans` family. `page-title` for the column's title, `title1` for the pane's title, `title2` for section headings, `headline` for row titles and labels, `body` for reading, `callout` for meta lines, `caption` for group and column headers and key caps (letter-spacing 0.2px, `ink-secondary`).
- `score` on the pane and `score-small` in rows, tabular figures. `mono` for model names and masked keys.
- Text follows the system text size in the Mac app (text styles), except the two score styles.
- Titles are sentence case. Group headers are sentence case too ("Needs a full read"), never all caps.

## Spacing and layout

- A 4 px grid. `space-7` (32) is the margin around a pane's content and a page; `space-6` (24) between sections; `space-4` (16) is a row's side padding; `space-2` (8) between buttons.
- Three columns: sidebar · list (`list-width`) · pane (at least `pane-min-width`). Settings and sheet forms are `form-width` wide and left-aligned.
- Rows are `row-height` (36) with one line of text and a meta line only when the row needs it; tables with a reason line use `row-height-comfortable`.
- The sidebar item is `sidebar-item-height` (28). The toolbar is the system's.
- Generous outside, compact inside: margins and section gaps are wide; rows and controls are tight.

## Shape

- `radius-capsule` for buttons, pills and chips; `radius-field` for fields and the selected row; `radius-card` for cards; `radius-group` for grouped boxes and sheets; `radius-keycap` for key caps. On macOS 26 nested corners are concentric: a card inside a group box takes the group's radius minus the padding.
- Mini, small and medium controls stay rounded rectangles; large ones are capsules. Shadows only on board cards and popovers (`shadow-card`, `shadow-popover`).
- Liquid Glass only on navigation: the sidebar, the toolbar, the menu bar popover. Content is solid `surface`.

## Components

- **Sidebar:** five working sections, then Reports and Setup. A badge is a `caption` count in `ink-secondary`. The footer is the app's one status line: `callout` text, a 6 px meter (`accent` on `separator`, `maybe` when a run stopped early), and Stop while something runs.
- **Column title:** `page-title` with a `callout` count line in `ink-secondary` beneath, `space-7` from the top and sides.
- **Job row:** verdict pill, title in `headline`, company · place in `callout` `ink-secondary`, the match in `score-small` at the trailing edge, a small `accent-text` document glyph when a resume exists. Selected: `accent-tint` with `radius-field`. Hover: `surface-raised` and the row's actions appear.
- **Group header:** `caption` in `ink-secondary` with the count: "Decide · 247". "No from the AI" collapses.
- **Action button with a key cap:** the label in `headline`; the key cap at the trailing edge: `caption` on `surface-raised`, a 1 px `outline` border, `radius-keycap`, 16 px tall. One primary (`accent`, white text) per view; the others `control-fill` with `ink`.
- **Verdict card:** on `surface-raised` with a `separator` hairline and `radius-card`: the pill, the `score`, the deciding reason in `body`, provenance as a tooltip.
- **Requirement row:** a 16 px glyph (`yes` filled check, `maybe` half circle, `ink-secondary` dashed circle), the requirement in `body`, the evidence in `callout` `ink-secondary` on one line.
- **Empty state:** `title2` title, one `body` line in `ink-secondary`, at most one button, no icon, centred in the column.
- **Form section:** `title2` title, `callout` caption, the controls, a `separator` hairline after.
- **Board card:** `surface` on `surface-sunken`, `shadow-card`, `radius-card`; company in `headline`, role in `callout`, a due follow-up in `maybe` with a bell and words.
- **Snippet callout:** `surface-raised`, `radius-card`, an info glyph, "Only a snippet of this posting came from Adzuna", with Open posting as a plain button.

## Iconography

- SF Symbols only, at the text's size. Verdicts: `checkmark.circle` (Yes), `circle.lefthalf.filled` (Maybe), `minus.circle` (No). Status: `paperplane` (Applied), `phone` (Screen), `person.2` (Interview), `gift` (Offer), `clock` (waiting), `bell` (follow-up), `doc.text` (resume), `arrow.clockwise` (find or re-evaluate), `exclamationmark.triangle.fill` (error). In the mockups the closest drawn glyph stands in; never a hand-drawn set of its own.
- An icon never stands alone for a state: it sits beside its word.

## Logo

- The mark is "Moment": a dial whose hand lands on a blue dot on its rim. Use the files in the Logo group as they are. Keep clear space of at least the dot's width. Below 48 px use the small version. The dot is the only colour: `accent` (`accent-text` on dark). Don't rotate the hand, recolour the ring or add effects.
- The wordmark is Instrument Sans Semibold; the lockup files carry it.

## Keyboard

- Every decision has one key, shown on its button: B build, S save, X skip, O open posting, A mark applied, V verdict, R re-evaluate; ↑↓ move; Return opens full width; Esc goes back; ⌘Z undoes a Save or Skip; ⌘R finds new jobs; ⌘1 to ⌘5 switch sections; ⌘F searches.
- Single keys act only while a list or pane has focus; in a text field they type.
