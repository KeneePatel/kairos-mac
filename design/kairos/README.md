# Kairos design reference (v2)

This folder is the visual spec for Kairos: a native macOS 26 app with a small phone web app. It finds US and Canadian software jobs (Canada first) and builds a tailored resume for each one. v2 (approved 2026-10-26, ADR-017) reorganised the app around an inbox of jobs to decide and refreshed the look: calm, warm neutrals, compact rows, one key per decision.

- `tokens.json` holds every colour (light and dark), the type scale, spacing, radii and shadows. Code reads its values from here through `scripts/gen-tokens.swift`.
- `BRAND.md` is the brand book: voice and copy, colour, type, spacing, shape, components, iconography, logo and keyboard rules, each naming the tokens it uses. Read it before any UI change.
- `components/` has one folder per component: guidelines (`README.md`) and a live preview (`preview.html`, rendered against the design system's `tokens.css`).
- `screens/` has one `.dc.html` per screen. Open any of them in a browser.
- `logo/` holds the app icon, the menu bar icon, the mark and wordmark lockups (see Logo below).
- `v1/` keeps the 2026-10-18 design (its README, tokens and screens) for the record.
- The source canvases are the "Kairos" design system and the "Kairos v2 screens" canvas on claude.ai. They're private to Kenee, so treat this folder as the copy you work from.

## How to read the screen files

Each `screens/*.dc.html` file is a static HTML mockup from the design canvas. Inline `style="…"` attributes and the `<helmet><style>` block hold the exact values: sizes, spacing, colours and font weights.

You can ignore these parts:

- the canvas wrapper: `<x-dc>`, `<helmet>`, `support.js` and the `<script type="text/x-dc">` block
- the grey window buttons, which the OS draws in the real app
- the hand-drawn SVG icons; use the closest SF Symbol instead (see Platform mapping)

These files show layout, hierarchy, copy and state. They aren't code to port line by line.

## Screens

| File | Screen | Size | What it shows |
| --- | --- | --- | --- |
| `Main.dc.html` | Inbox, light | 1440×900 | Sidebar (five working sections, Reports, Setup, the status footer) · toolbar: search, Filter, Sort, Find new jobs · the list: Decide, Needs a full read, No from the AI · the job pane: title, Build / Save / Skip / Open posting with their keys, the verdict card, must-haves and nice-to-haves with evidence, where it's posted, the posting |
| `InboxDark.dc.html` | Inbox, dark, while finding jobs | 1440×900 | The same screen in dark mode; the footer shows a run with its meter and Stop |
| `InboxZero.dc.html` | Inbox, nothing to decide | 1440×900 | The empty state in the list; the pane shows Today: counts, what's due, what's saved |
| `Job.dc.html` | Job, full width | 1440×900 | The job after Return: Inbox back button, Previous and Next, the whole posting |
| `Resumes.dc.html` | Resumes | 1440×900 | Builds grouped Building, Today, Yesterday · the resume page: Mark applied, Open posting, Save PDF, Build again, Resume / Cover letter, the PDF, the inspector (match, build, selected line, checks, Be ready to discuss) |
| `MenuBar.dc.html` | Menu bar item | 380×520 | To decide, need a full read, verdict tiles, new since you looked, a running build, Find new jobs, Open Kairos |
| `Applied.dc.html` | Applied | 1440×900 | Scope control (Waiting, In progress, Closed, All) · the table · the application pane: status with Move to, next step, follow-up, timeline, notes |
| `Interviews.dc.html` | Interviews | 1440×900 | The board of Screen, Interview and Offer · the same application pane |
| `Sources.dc.html` | Sources | 1440×900 | Yours, Catalog, All · the companies table · the source pane: status, open roles for you, what the filters dropped, history · Add |
| `Settings.dc.html` | Settings, Search | 1440×900 | A left list (General, Search, AI, Account) · the Search form: roles, titles, skipped titles, levels, where, limits |
| `MasterResume.dc.html` | Master resume | 1440×900 | Contact, About you, Experience, Skills as hairline sections · readiness in the inspector |
| `FilteredOut.dc.html` | Filtered out | 1440×900 | Reasons with counts · the dropped jobs with Bring back · Change levels |
| `Improve.dc.html` | Improve | 1440×900 | Fixes ranked by the verdicts they could move · the detail: what your resume shows, what the jobs ask |

## Rules that hold everywhere

1. **Verdicts:** Yes is green, Maybe is amber and No is grey. Always pair the colour with its icon and its word, and never use colour alone. "No" rows, skipped jobs and applied jobs are dimmed with `ink-dimmed`, not with opacity.
2. **One accent:** blue (`accent`) fills only the one primary button a view allows and the selected segment; `accent-tint` the selected row; `accent-text` links. Nothing else is blue.
3. **Glass on navigation only:** the sidebar, toolbar controls, the menu bar popover and the phone tab bar. Content panels are solid `surface`.
4. **Quiet surfaces:** cards are `surface-raised` with a `separator` hairline, never a filled grey box without an edge. Shadows only on board cards and popovers.
5. **One key per decision,** shown on its button as a key cap: B build, S save, X skip, O open posting, A mark applied, V verdict, R re-evaluate; ↑↓ move; Return opens full width; Esc goes back; ⌘Z undoes a save or skip; ⌘R finds new jobs; ⌘1 to ⌘5 switch sections.
6. **One status line:** the sidebar footer says what Kairos is doing, with Stop. No other screen announces a run, except the resume page for its own build.
7. **Avoid:** purple or indigo, gradients, emoji, left-border accent cards, fake status bars, oversized padding, sentences that explain the mechanism on a working screen (put provenance in a tooltip, cost on the control).
8. **Contrast:** text needs at least 4.5:1 in both themes and control outlines 3:1. Every text pair in `tokens.json` passes; ratios are in each token's `usage`. Phone touch targets are at least 44 px.
9. **Requirement states:** a solid green check means Shown. An amber half circle means Partly shown. A dashed grey circle means Not shown. The evidence line names what matched, for example "Shown · RabbitMQ".
10. **Skill chips:** Proven chips are solid and Can discuss chips are dashed. Metric chips are square-cornered with a small chart mark.
11. **Resumes:** they only claim Proven skills. Can discuss skills appear only in Stretch mode, and each one goes on that build's "Be ready to discuss" list.

## Type

The app uses SF Pro (the system font). The scale lines up with the macOS text styles, so text follows the user's size settings; the two scores are fixed.

| Role | Size / line height | Weight | macOS style |
| --- | --- | --- | --- |
| Page title (column title) | 26/32 | Bold | `.largeTitle` |
| Title 1 (pane title) | 22/28 | Bold | `.title` |
| Title 2 (section heading) | 17/22 | Semibold | `.title2` |
| Headline (row title, labels) | 13/18 | Semibold | `.headline` |
| Body | 13/18 | Regular | `.body` |
| Callout (meta line) | 12/16 | Regular | `.callout` |
| Caption (group and column headers, key caps) | 11/14 | Medium | `.subheadline` |
| Score (pane) | 24/28 | Bold, tabular figures | custom |
| Score, small (rows) | 15/20 | Bold, tabular figures | custom |
| Mono (model names, masked keys) | 12/16 | Regular | `.callout`, monospaced |
| Phone and resume styles | as in `tokens.json` | | web and PDF only |

Use tabular figures for every number that lines up in a column: scores, counts and times.

## Spacing and radii

- **Spacing:** 4 px base (4, 8, 12, 16, 20, 24, 32). `space-7` (32) is the margin around a pane's content; `space-6` (24) between sections; `space-4` (16) is a row's side padding.
- **Layout:** rows 36 px (48 for two-line table rows) · sidebar items 28 px · the list column 320 to 420 px · the pane at least 480 px · forms 640 px · the toolbar is the system's.
- **Radii:**

  | Radius | Used on |
  | --- | --- |
  | 4 | key caps |
  | 6 | metric chips and badges |
  | 8 | fields, pop-ups, selected rows |
  | 10 | cards |
  | 12 | grouped boxes, tables, sheets |
  | 18 to 20 | sidebar and popover |
  | capsule | buttons, segmented controls, verdict pills and skill chips |

  On macOS 26 nested corners are concentric: a card inside a group box takes the group's radius minus the padding.

## Platform mapping

### macOS app (SwiftUI)

- **Layout:** `NavigationSplitView` for the sidebar and content. Inside a section, the list and the pane are one content panel split by a hairline (`ListPaneLayout`), not a third navigation column. `.inspector` for the master resume's readiness and the resume page's details. Put toolbar items in `.toolbar`; the sidebar footer is a `safeAreaInset`.
- **Glass:** built this way, the sidebar and toolbar get Liquid Glass from the system on macOS 26. Don't hand-draw glass, and don't put glass on content.
- **Controls:**
  - scopes (Waiting · In progress · Closed · All; Yours · Catalog · All) and Resume / Cover letter: `Picker` with `.segmented` style
  - switches: `Toggle` with `.switch` style
  - status and model choices: pop-up `Picker`
  - lists: `List` with 36 pt rows; tables with several columns (Applied, Sources): `Table`
  - decisions: `Button` with the key cap at the trailing edge, one `.borderedProminent` per view; shortcuts through `.keyboardShortcut` and the Job menu
- **Menu bar:** `MenuBarExtra` with `.menuBarExtraStyle(.window)`.
- **Colours:** one Asset Catalog colour set per token in `tokens.json`, with Any and Dark appearances, generated by `scripts/gen-tokens.swift`.
- **Icons:** use SF Symbols:

  | Use | Symbol |
  | --- | --- |
  | Yes / Shown | `checkmark.circle` (filled for Shown) |
  | Maybe / Partly shown | `circle.lefthalf.filled` |
  | No | `minus.circle` |
  | Not shown | `circle.dashed` |
  | Inbox · Saved · Resumes · Applied · Interviews | `tray` · `bookmark` · `doc.text` · `paperplane` · `person.2` |
  | Improve · Filtered out · Skipped | `chart.line.uptrend.xyaxis` · `line.3.horizontal.decrease` · `minus.circle` |
  | Master resume · Sources · Settings | `person.text.rectangle` · `antenna.radiowaves.left.and.right` · `gearshape` |
  | Find new jobs, re-evaluate | `arrow.clockwise` |
  | Follow-up due | `bell` |
  | Source error, failed build | `exclamationmark.triangle.fill` |

  For the other icons, pick the closest match to the drawn one.
- **Resume PDF:** bundled Liberation Serif for the Harvard template, Source Serif 4 (SIL Open Font License) for Classic.

### Phone web app

- **Colours:** expose `tokens.json` as CSS custom properties, with dark values under `prefers-color-scheme: dark`.
- **Fonts:** use the `-apple-system, BlinkMacSystemFont, system-ui` font stack.
- **Tab bar and actions:** the tab bar floats above the content and pads with `env(safe-area-inset-bottom)`. The job detail screen pins its actions to the bottom.
- **Don't draw:** a status bar or keyboard. The phone screens are not redrawn in v2; use `v1/screens/Phone*.dc.html` with the v2 tokens.

## Logo

The logo is "Moment": a dial with one hand landing on a blue point on its rim. The ring is broken around the dot so they never touch.

### Files

| File | Use it for |
| --- | --- |
| `logo/icon-composer/dial.svg` and `logo/icon-composer/moment.svg` | The macOS 26 app icon. Each is a layer on a 1024 px canvas: ring, hand and pivot in one, the blue dot in the other. Build the icon from them in Icon Composer. Background: `#FFFFFF` in Default and `#1D1D1F` in Dark. Layer colours: `#1D1D1F` / `#0B63CE` in Default and `#F2F2F5` / `#5AA2FF` in Dark. |
| `logo/app-icon-default.svg`, `app-icon-dark.svg`, `app-icon-tinted.svg` | The finished icon in each appearance, with its tile. Use them for previews and docs, or as the asset-catalog icon if you're not using Icon Composer. |
| `logo/app-icon-small.svg` | 16 and 32 px sizes, with heavier strokes and no pivot. It's also the web app's SVG favicon. |
| `logo/png/` | PNG exports: 1024 down to 64 px for both themes, a 180 px phone home-screen icon (`app-icon-default-180.png`), and 16 and 32 px from the small version. |
| `logo/menubar-template.svg` | The menu bar icon at 18 × 18. Add it to the asset catalog with "Render As: Template Image" and "Preserve Vector Data", and use it as the `MenuBarExtra` label. macOS recolours it, so leave it black. |
| `logo/mark.svg` | The mark with no tile, for in-app use on light grounds, such as the sign-in screen and About window. |
| `logo/lockup-light.svg` and `lockup-dark.svg` | The icon beside the "Kairos" wordmark. |

### Wordmark

The wordmark is Instrument Sans Semibold, set at 48 px with −0.8 px letter spacing. It's free to use under the SIL Open Font License, from Google Fonts.

The lockup files use live text, so on a machine without the font installed they show a fallback. Before using a lockup outside the app, convert the text to outlines: download Instrument Sans and use fontTools or any vector editor.

### Rules

- Keep clear space around the mark at least the width of the blue dot.
- Below 48 px, use the small version.
- The dot is the only colour: `accent` blue (`accent-text` blue on dark).
- Don't rotate the hand, recolour the ring, add gradients or effects, or put the dot anywhere else on the ring.

## Sample data

The screens use a fictional persona, Jordan Rivera (backend developer in Toronto), and fictional companies (Northline Freight, Maplepay, Tidewater Health and others). The counts on the v2 screens are the owner's real ones from 2026-10-26.

- Use them for previews, fixtures and tests only. Never ship them as real data.
- The job boards (Greenhouse, Lever, Ashby, Adzuna and the rest) are real services.
- So are the AI providers (Gemini, Ollama). The model names on the screens are examples, so check the current names before hard-coding any.

## Known gaps

- **Dark mode:** only the Inbox is drawn in dark. Derive the other screens from the dark values in `tokens.json`.
- **Settings:** only the Search page is drawn. General, AI and Account reuse its form pattern.
- **Saved and Skipped:** not drawn; they are the Inbox's list and pane with their own title and actions (Skipped shows Bring back instead of Skip).
- **Phone and the menu bar in dark:** not drawn.
