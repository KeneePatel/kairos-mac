<img src="design/kairos/logo/png/app-icon-default-128.png" width="64" height="64" alt="Kairos app icon">

# Kairos for macOS

Kairos finds software jobs in Canada and the US, Canada first, says which ones fit and why, and builds a tailored resume and cover letter for the ones worth applying to. It's a native macOS app, and everything stays on your Mac.

**Status:** in daily use by its owner. Rebuilt from the ground up on 2026-10-28 (ADR-019); the first version's data imports on first launch.

## What it does

- **Finds jobs** on companies' own boards (Greenhouse, Lever, Ashby, SmartRecruiters, Workable, Recruitee, Personio, BambooHR, Teamtailor), from a bundled catalog of about 800 Canadian boards, Himalayas and Google Jobs, and follows Adzuna's leads back to the companies' boards.
- **Screens them** with free filters first (roles, levels, places, work authorization, clearance, French, agencies, age), then one AI read of each posting. Code turns that read into Yes, Maybe or No, and shows which requirements your resume covers.
- **Builds a resume** for a job from your master resume, the one record of everything you've done. Every line traces back to it, and a verifier checks each claim before the PDF is made.
- **Tracks applications** from applied to offer, with follow-ups, notes and a timeline.
- **Shows what to improve:** the asks that keep your Maybe and No jobs from a Yes, ranked by the verdicts each could move.

## Built with

- Swift 6 and SwiftUI on macOS 26 (Apple silicon), with no third-party Swift packages
- SQLite through a thin wrapper, Typst for PDFs
- Your choice of AI: Gemini, Ollama (on your Mac or in the cloud), Groq, OpenRouter, OpenAI, or any OpenAI-compatible endpoint, with your own keys

## Documents

| File | What's in it |
| --- | --- |
| [`docs/product.md`](docs/product.md) | What the app does: sources, screens, verdicts, resumes, data |
| [`docs/architecture.md`](docs/architecture.md) | How it's built: modules, data, fetching, screening, builds |
| [`docs/guides/development.md`](docs/guides/development.md) | Setting up, everyday commands, the `kairos` tool, debug modes |
| [`docs/decisions/`](docs/decisions/) | Why: one record per decision (ADR-019 is the rebuild) |
| [`docs/rebuild.md`](docs/rebuild.md) | What the 2026-10-28 rebuild changed, and how it was checked |
| [`CONSTRAINTS.md`](CONSTRAINTS.md) | The quality bar every change must pass |
| [`design/kairos/`](design/kairos/README.md) | Brand guidelines, design tokens, screens and the logo |
| [`AGENTS.md`](AGENTS.md) | Rules for AI coding agents working in this repo |

## Repository

```
App/                 the macOS app (XcodeGen project, feature folders under App/Kairos)
Packages/KairosCore/ the core: one target per module, tests and fixtures
design/kairos/       the visual spec and tokens
docs/                product, architecture, guides, decisions, research, archive
evals/               prompt eval reports
scripts/             checks, token generation, typst fetching, live checks
```

## Credits

Kairos for macOS is a rebuild of [Kairos](https://github.com/sneh2102/Kairos) by Sneh Patel, released under the MIT License. It's written from scratch; if any code or prompts from the original are reused, its copyright notice will be kept alongside them.

## License

[MIT](LICENSE)
