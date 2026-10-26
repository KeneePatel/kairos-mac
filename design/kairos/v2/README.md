# Kairos design v2 (draft, 2026-10-26)

The proposed look and structure for the UI redesign (`docs/design/ui-v2/`, ADR-017). It stays in this folder until the owner approves it; the approval slice then makes it `design/kairos/` and moves v1 to `design/kairos/v1/`.

- `tokens.json`: v2 tokens, the same shape `scripts/gen-tokens.swift` reads. Warm neutrals (`window`, `surface`, `surface-raised`, `surface-sunken`), an `outline` colour for control edges, a `page-title` style, a 36 px `row-height`, `radius-keycap`, and a `shadow` family. Every text pair passes 4.5:1 in both themes (checked by script); the usage notes carry the ratios.
- `BRAND.md`: the brand book: voice, colour, type, spacing, shape, components, iconography, logo, keyboard. The same text is the README of the "Kairos" design system on claude.ai.
- `components/`: one folder per component with its guidelines (`README.md`) and a live preview (`preview.html`, rendered against the design system's `tokens.css`).
- `screens/`: the thirteen artboards of the "Kairos v2 screens" canvas, as `.dc.html` (the same format as `../screens/`). Open any in a browser. `Main` is the Inbox.

| File | Screen |
| --- | --- |
| `Main.dc.html` | Inbox, light: sidebar · list (Decide, Needs a full read, No from the AI) · job pane with Build, Save, Skip, Open posting |
| `InboxDark.dc.html` | Inbox, dark, while Find new jobs runs (status footer with a meter and Stop) |
| `InboxZero.dc.html` | Inbox with nothing to decide; the pane shows Today |
| `Job.dc.html` | A job full width (Return), with Previous and Next |
| `Resumes.dc.html` | Builds list · the resume page: PDF, match, build, selected line, checks |
| `MenuBar.dc.html` | The menu bar item (380 × 520) |
| `Applied.dc.html` | The applications table (In progress scope) · application pane |
| `Interviews.dc.html` | The board of Screen, Interview and Offer · the same pane |
| `Sources.dc.html` | Companies table (Yours · Catalog · All) · source pane |
| `Settings.dc.html` | Settings with a left list; the Search page |
| `MasterResume.dc.html` | The master resume with readiness in the inspector |
| `FilteredOut.dc.html` | Reasons · the dropped jobs with Bring back |
| `Improve.dc.html` | Fixes ranked by the verdicts they could move · the detail |

Sample data only (Jordan Rivera and the mockup companies; the real counts are the owner's from 2026-10-26).
