# Kairos design reference

This folder is the visual spec for Kairos: a native macOS 26 app with a small phone web app. It finds US and Canadian software jobs (Canada first) and builds a tailored resume for each one.

- `tokens.json` holds every colour (light and dark), the type scale, spacing and radii. Code should read its values from here.
- `screens/` has one file per screen. Open any of them in a browser to see it.
- `logo/` holds the app icon, the menu bar icon, the mark and wordmark lockups (see Logo below).
- The source canvas is the "Kairos" Design artifact on claude.ai. It's private to Kenee, so treat this folder as the copy you work from.

## How to read the screen files

Each `screens/*.dc.html` file is a static HTML mockup from the design canvas. Inline `style="…"` attributes hold the exact values: sizes, spacing, colours and font weights.

You can ignore these parts:

- the canvas wrapper: `<x-dc>`, `<helmet>`, `support.js` and the `<script type="text/x-dc">` block
- the red, yellow and green window buttons, which the OS draws in the real app
- the blur and translucency done with CSS `backdrop-filter`, which stands in for the system's Liquid Glass
- the hand-drawn SVG icons; use the closest SF Symbol instead (see Platform mapping)

These files show layout, hierarchy, copy and state. They aren't code to port line by line.

## Screens

| File | Screen | Size | What it shows |
| --- | --- | --- | --- |
| `Main.dc.html` | Today, light | 1440×900 | Sidebar · verdict filter and "Run now" toolbar · jobs grouped Canada then US, ranked by verdict, then score · inspector for the selected job (score, verdict, must-haves and nice-to-haves with the matched skill, three actions) |
| `TodayDark.dc.html` | Today, dark | 1440×900 | The same screen in dark mode. The only screen drawn in both themes. |
| `Build.dc.html` | Build | 1440×900 | Three columns: build steps and match-score breakdown · letter-size resume preview in Source Serif 4 · selected line traced to its master-resume bullet, the checks it passed, and "Be ready to discuss" (empty while Stretch mode is off). Toolbar: Full / Lite, Save PDF, Mark applied. |
| `MasterResume.dc.html` | Master resume | 1440×900 | Contact form: name, email, phone and LinkedIn required; GitHub and portfolio optional; the portfolio field shows a validation error · experience entry with metric chips and skill chips · Proven (solid) and Can discuss (dashed) skills · "Ready to build" status |
| `Applications.dc.html` | Applications | 1440×900 | Board columns Applied, Screen, Interview, Offer, Closed · side panel with the selected application's status pop-up, timeline, follow-up reminders and notes |
| `Sources.dc.html` | Sources | 1440×900 | Company watchlist table (board, locations kept, open roles, status, including one error row) · opt-in boards with a caution note and switches · side panel with job titles and countries in priority order |
| `SettingsAI.dc.html` | Settings · AI providers | 1440×900 | Gemini card with masked keys and Ollama card with local models · "Which model does what" table with daily caps · privacy panel (what leaves the Mac; contact details are never sent) |
| `SignIn.dc.html` | Sign in | 1040×680 | Kairos mark · email and password, Google and GitHub, invite-only note, "Use Kairos on this Mac without an account" |
| `MenuBar.dc.html` | Menu bar popover | 380×540 | Next run, Yes / Maybe / No counts, new jobs, build in progress, sync status |
| `PhoneToday.dc.html` | Phone · Today | 390×844 | Large title, four-way verdict filter, Canada list first, floating glass tab bar |
| `PhoneJob.dc.html` | Phone · Job detail | 390×844 | Score and verdict, must-haves, collapsed nice-to-haves, pinned actions: "Build resume on my Mac", "Mark applied", "Not for me" |
| `Foundations.dc.html` | Foundations | 1440 wide | Colour tokens, type scale, spacing, radii, controls and the do and don't list |

## Rules that hold everywhere

1. **Verdicts:** Yes is green, Maybe is amber and No is grey. Always pair the colour with its icon and its word, and never use colour alone. "No" rows are dimmed with the `ink-dimmed` colour, not with opacity.
2. **One accent:** blue (`accent`) marks only the primary action and the current selection. Allow one primary button per view.
3. **Glass on navigation only:** the sidebar, toolbar controls, the menu bar popover and the phone tab bar. Content panels are solid.
4. **Avoid:** purple or indigo, gradients, emoji, left-border accent cards, fake status bars and oversized padding.
5. **Contrast:** text needs at least 4.5:1 in both themes. Every text pair in `tokens.json` passes; ratios are in each token's `usage`. Phone touch targets are at least 44 px.
6. **Requirement states:** a solid green check means Covered. A dashed grey circle means Missing. The meta line always names the matched skill, for example "Covered · Matched: RabbitMQ, an equivalent".
7. **Skill chips:** Proven chips are solid and Can discuss chips are dashed. Metric chips are square-cornered with a small chart mark.
8. **Resumes:** they only claim Proven skills. Can discuss skills appear only in Stretch mode, and each one goes on that build's "Be ready to discuss" list.

## Type

The app uses SF Pro (the system font). The scale lines up with the macOS text styles:

| Role | Size / line height | Weight | macOS style |
| --- | --- | --- | --- |
| Title 1 | 22/28 | Bold | `.title` |
| Title 2 (inspector heading) | 17/22 | Bold | `.title2` |
| Title 3 (window title, section) | 15/20 | Bold | `.title3` |
| Headline (row title) | 13/18 | Semibold | `.headline` |
| Body | 13/18 | Regular | `.body` |
| Callout (meta line) | 12/16 | Regular | `.callout` |
| Caption (table header) | 11/14 | Semibold | `.subheadline` |
| Score | 28/32 | Bold, tabular figures | custom |
| Phone large title / body | 32/38 Bold · 15/20 | | web only |
| Resume | Source Serif 4: name 22, body 10.5/14, section labels 9.5 caps | | PDF only |

Use tabular figures for every number that lines up in a column: scores, counts and times.

## Spacing and radii

- **Spacing:** 4 px base (4, 8, 12, 16, 20, 24).
- **Layout:** panel padding 18 to 20 px · toolbar 52 px tall · desktop rows 48 px · sidebar items 30 px · phone rows 84 px.
- **Radii:**

  | Radius | Used on |
  | --- | --- |
  | 6 | metric chips |
  | 8 | fields and pop-ups |
  | 10 | rows and cards |
  | 12 to 14 | grouped boxes |
  | 18 to 20 | sidebar and popover |
  | capsule | buttons, segmented controls, verdict pills and skill chips |

## Platform mapping

### macOS app (SwiftUI, if that's the stack)

- **Layout:** use `NavigationSplitView` for the sidebar and content, and `.inspector` for the right-hand panel. Put toolbar items in `.toolbar`.
- **Glass:** built this way, the sidebar and toolbar get Liquid Glass from the system on macOS 26. Don't hand-draw glass, and don't put glass on content.
- **Controls:**
  - verdict filter and Full / Lite: `Picker` with `.segmented` style
  - switches: `Toggle` with `.switch` style
  - status and model choices: pop-up `Picker`
  - Today list: `List` or `Table` with Canada and United States sections
- **Menu bar:** `MenuBarExtra` with `.menuBarExtraStyle(.window)`.
- **Colours:** one Asset Catalog colour set per token in `tokens.json`, with Any and Dark appearances.
- **Icons:** use SF Symbols:

  | Use | Symbol |
  | --- | --- |
  | Yes | `checkmark.circle` |
  | Maybe | `circle.lefthalf.filled` |
  | No | `minus.circle` |
  | Run now | `arrow.clockwise` |
  | Source error | `exclamationmark.triangle.fill` |

  For the other icons, pick the closest match to the drawn one.
- **Resume PDF:** bundle Source Serif 4 (SIL Open Font License) for rendering, or use the system New York serif if you'd rather not bundle a font.

### Phone web app

- **Colours:** expose `tokens.json` as CSS custom properties, with dark values under `prefers-color-scheme: dark`.
- **Fonts:** use the `-apple-system, BlinkMacSystemFont, system-ui` font stack.
- **Tab bar and actions:** the tab bar floats above the content and pads with `env(safe-area-inset-bottom)`. The job detail screen pins its actions to the bottom.
- **Don't draw:** a status bar or keyboard.

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

The screens use a fictional persona, Jordan Rivera (backend developer in Toronto), and fictional companies (Northline Freight, Maplepay, Tidewater Health and others).

- Use them for previews, fixtures and tests only. Never ship them as real data.
- The job boards (Greenhouse, Lever, Ashby, Workday, Job Bank, Wellfound, Hacker News, Remotive) are real services.
- So are the AI providers (Gemini, Ollama). The model names on the Settings screen are mockup examples, so check the current names before hard-coding any.

## Known gaps

- **Dark mode:** only Today is drawn in dark. Derive the other screens from the dark values in `tokens.json`. The phone and the menu bar popover aren't drawn in dark at all.
- **Control outlines are too faint:** text-field borders (`#C9C9CF`) and the off-switch track (`#D1D1D6`) are under the 3:1 contrast needed for control outlines. System controls in the macOS app handle this for you. In the web app, use `field-border-strong` from `tokens.json` (`#86868D` light, `#7C7C83` dark).
- **Collapsed sections:** the United States section in the phone Today list and the phone Nice-to-haves section are drawn collapsed.
- **Sign-in buttons:** "Continue with Google" and "Continue with GitHub" are text-only placeholders. Use each provider's official sign-in button assets.
