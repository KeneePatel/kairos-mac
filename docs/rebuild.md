# The 2026-10-28 rebuild

Kenee asked for the whole project rebuilt from the ground up, with every decision delegated: "make any decisions you want. Test and research everything, cross check everything and make it better this time. Also organize every file in this project."

This file records what the rebuild decided and why, and tracks its progress. It's written for whoever reviews the `rebuild` branch.

## What was wrong with the old tree

The old app worked: about 755 tests passed and it was in daily use. It had grown by accretion, though:

- **One object ran the app.** `AppModel.swift` was 1,342 lines holding every screen's state and action, and 2,000+ lines of debug reports and probes lived inside the app target.
- **Iterations left layers.** UI v1 → v2, job collection v1 → v2 → v3 and resume builder v1 → v2 each left migrations that archive the last version's rows, unused templates, superseded prompts and columns for a sync that was never built (`updated_hlc` on every table, `sync_outbox`, `artifact.storage_path`).
- **The documents were changelogs.** `SPEC.md` (96 KB) described each change with its date, `tasks/todo.md` was a 185 KB log, and the README promised accounts, sync and a phone app that don't exist.
- **Two HTTP stacks,** one for job sources and one for the AI, each tested through a `URLProtocol` hack.
- **35 stale branches** and build output in the repository folder.

## Decisions

| # | Decision | Why |
|---|---|---|
| R1 | **Same product, rebuilt.** Find jobs, screen them, build a tailored resume and letter, track applications. The v2 look (ADR-017) and the screening rules Kenee approved stay. | The workflow was proven in real use; the foundations were what needed redoing. |
| R2 | **Pure domain modules, one persistence module, one engine.** `Jobs`, `Resume`, `Screening`, `Tailoring` and `AI` hold logic and types with no SQLite. `Store` holds the schema and repositories. `Engine` runs fetches, screening and builds. | Logic is testable without a database, persistence is in one place, and orchestration is in one place. |
| R3 | **One HTTP client protocol** with value types, shared by sources and the AI layer; tests pass a fake. | Simpler and faster tests; one place for timeouts, user agent and conditional requests. |
| R4 | **A new schema, and an importer.** The old database is never migrated in place: on first launch the app copies it to `Backups/` and imports it read-only (master resume with its ids, applications, builds and PDFs, settings, sources, jobs and their screening). API keys stay in the same file and carry over untouched. | A bad migration can't damage the only copy of the master resume, and the old app still opens its own file. |
| R5 | **No sync columns until sync exists.** Rows carry `updated_at`; foreign keys with cascades keep integrity. Accounts, sync and the phone web app move to the roadmap. | They were never built. Sync will add what it needs. |
| R6 | **Debug tools become a CLI.** `kairos` (a SwiftPM executable) fetches, screens, builds and reports against any database file. The app keeps only a small debug-only snapshot mode for checking screens. | Debug code out of the app; tools usable on a copy of the data. |
| R7 | **Fewer AI calls per build.** The rewrite loop (2–4 calls that the old docs said often made sections worse) is dropped; the match score stays as a report. Writers run in parallel; any step that fails falls back to the master resume's own words. | Free tiers allow as few as 20 Flash calls a day. |
| R8 | **Faster fetches.** Boards are read with a per-host limit rather than one global limit, with ETags. | The old fetch took about 3.5 minutes for 599 sources. |
| R9 | **Documents describe the system as it is.** A short README, `docs/product.md`, `docs/architecture.md`, ADRs, guides; the old spec, plan and task log move to `docs/archive/`. | Readers need the current state, not its history. |
| R10 | **Work on the `rebuild` branch;** `main` is left alone for Kenee to merge after review. | The rebuild replaces every file. |

## Research and cross-checks (2026-10-28)

- Every public board API the app reads answered live with the fields the readers expect: Greenhouse (713 Stripe jobs, light list 445 KB versus 5.5 MB with content), Lever, Ashby, SmartRecruiters, Workable, Recruitee, Personio (XML), BambooHR, Teamtailor (RSS) and Himalayas (20 a page, `limit` ignored). Greenhouse, Lever and Ashby send ETags.
- Typst 0.15.1 (July 2026) is still the current release, so the pinned binary stays.
- Published Gemini free-tier limits disagree with each other, which supports learning the real daily limit from the provider's own refusal, as the old app did.
- Local Ollama (0.40, `qwen3.5:4B`) is available for end-to-end AI checks that spend nothing.

## Progress

- [ ] Foundation: `KairosKit`, `SQL`, `Secrets`, test kit
- [ ] `Jobs`: types, geography, roles, normalizer, de-duplication, ATS detection, catalog, readers
- [ ] `Resume`: model, validation, redaction, import tasks
- [ ] `AI`: providers, client, router, tasks, schema validation
- [ ] `Screening`: prefilter, analysis, verdict, ranking
- [ ] `Tailoring` and `Render`
- [ ] `Store`: schema and repositories
- [ ] `Engine`: fetch, screen, build, retention, importer
- [ ] `kairos` CLI
- [ ] App
- [ ] Documents, scripts, CI, file organisation
- [ ] Live checks: real boards, local Ollama end to end, app screens, import of the real database (read-only)
