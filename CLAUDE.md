@AGENTS.md

## Design

`design/kairos/` holds the brand guidelines: how Kairos should look and feel, plus the logo. Read `design/kairos/README.md` before any UI change, in the Mac app or the phone web app.

- **What it governs:** visuals only (colour, type, spacing, radii, layout feel, the logo). `docs/product.md` decides what the app does: features, job sources, screens and data. Where a mockup shows different content (for example other job boards or other sidebar items), follow `docs/product.md` and keep only the look.
- **Tokens:** colours (light and dark), type, spacing and radii come only from `design/kairos/tokens.json`: Asset Catalog colour sets in SwiftUI, CSS custom properties in the web app. Never hard-code a hex value in a view.
- **Mockups:** `design/kairos/screens/*.dc.html` are inspiration to rebuild with native components (system sidebar, toolbar, inspector, segmented pickers, switches, `MenuBarExtra`, SF Symbols), not code to port.
- **Visual rules to keep:**
  - every verdict shows colour, icon and word together
  - "No" rows are dimmed with `ink-dimmed`, not opacity
  - glass on navigation only
  - one primary button per view
  - text contrast at least 4.5:1
  - phone targets at least 44 px
- **Undrawn cases:** when the design doesn't cover something (an undrawn dark screen, an empty or error state, a new component), reuse existing tokens and patterns and tell the owner what you decided.
- **Sample data:** Jordan Rivera and the mockup companies are for previews and test fixtures only.
- **After each screen:** list every remaining visual difference from the closest `.dc.html` file, with the reason.
