# Spike T06: Typst inside the sandboxed, self-signed app

**Result: passed.** No fallback needed; ADR-004 (Typst instead of LaTeX) stands.
**Date:** 2026-10-19 · Typst 0.15.1 · macOS 27.0.1 · Xcode 27

## Question

Can the App Sandbox app run a bundled `typst` binary on JSON input and read back the PDF? If not, the fallback was WebKit printing (ADR-004).

## What was built

- `scripts/fetch-typst.sh` downloads `typst-aarch64-apple-darwin.tar.xz` for v0.15.1. It checks the SHA-256 against the digest GitHub publishes for that release asset (`48f62ed0…c05a`) and puts the binary in `Vendor/typst/` (gitignored).
- The `Render` target's `TypstRunner` writes the template and a `data.json` into a temporary folder and runs:

  `typst compile --root <tmp> --input data=data.json --ignore-system-fonts template.typ out.pdf`

  It returns the PDF bytes, Typst's own error text on failure, or a timeout.
- `App/project.yml` copies the binary into `Contents/MacOS/` with Code Sign On Copy, so it's signed along with the app.
- A debug-only route, `kairos://debug/render-spike`, runs a render from inside the app.

## Evidence

| Check | Result |
| --- | --- |
| Package test: JSON with `C# & R&D`, `50%`, `$5`, `snake_case`, `*stars*` → PDF | 1 page; every string found verbatim by PDFKit; about 0.1 s |
| Package test: broken template | `RenderError.compile` carrying Typst's message |
| App signature with typst inside | `codesign --verify --strict` passes; typst re-signed ad hoc |
| Render from the sandboxed app | Log: `render-spike: ok, 12662 bytes, 1 page(s), text found: true, 0.363 s` |
| Debug app bundle size | 43 MB on disk (typst is about 45 MB uncompressed) |

## What this settles

- **No escaping layer.** Characters that broke the original LaTeX pipeline are plain data to Typst, so no "LaTeX fixer" agent is needed.
- **The sandbox isn't a problem.** A child process inherits the app's sandbox and can use the app's temporary folder. With `--ignore-system-fonts` it only needs its embedded fonts.
- **Speed.** Renders take well under the spec's 1 s target (S8).

## Notes for later tasks

- **T32 (fonts):** bundle Source Serif 4 and pass `--font-path`. The spike used Typst's embedded fonts.
- **T07, T57 (signing):** the app is ad-hoc signed for now, and Xcode drops the hardened runtime for ad-hoc signing. Recheck the bundled binary once the self-signed certificate is in place.
- **Size:** the release bundle size gets measured at T57, against the 80 MB budget.
