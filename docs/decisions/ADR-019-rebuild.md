# ADR-019: Rebuild Kairos from the ground up on a layered core

## Status
Accepted 2026-10-28. The owner asked for the rebuild and delegated every decision ("make any decisions you want"); the `rebuild` branch waits for their review before it reaches `main`.

## Date
2026-10-28

## Context
The first Kairos worked and was in daily use, but it had grown by accretion: one 1,342-line `AppModel` ran the app, debug tools lived in the app target, three generations of UI, job collection and resume building each left migrations and columns behind, every table carried columns for a sync that was never built, and job sources and the AI each had their own HTTP stack. The spec and task list had become changelogs, and the README promised accounts, sync and a phone app that didn't exist. [`../rebuild.md`](../rebuild.md) lists the details.

## Decision
- Keep the product, the v2 design (ADR-017), job collection v3 (ADR-018) and the screening rules; rebuild the code.
- Split the core into foundations (`KairosKit`, `SQL`, `Secrets`), pure domain modules (`AI`, `Jobs`, `Resume`, `Screening`, `Tailoring`, `Render`), one persistence module (`Store`) and one orchestration module (`Engine`), plus the `kairos` tool. See [`../architecture.md`](../architecture.md).
- One HTTP client protocol for readers and the AI, with value types and a fake for tests.
- A new schema with foreign keys and no sync columns. The first Kairos's database is never migrated in place: the new app copies it to `Backups/` and imports it read-only, once.
- One AI router holding every reliability rule; the resume rewrite loop is dropped (the match score is a report).
- Debug reports move from the app into the `kairos` tool; the app keeps only the snapshot and import-check modes.
- Documents describe the system as it is (`product.md`, `architecture.md`, guides); the first spec, plan and task log move to `docs/archive/`.

## Consequences
- Accounts, sync and the phone web app (ADR-003, ADR-010, ADR-011, ADR-012) are deferred, not dropped: sync will add the columns and tables it needs. Until then, everything stays on the Mac.
- The rebuild replaces every test file; the floor guard flags the old ones as deleted, which needs the owner's sign-off on the pull request.
- A first launch imports the old data (verified on a copy of the owner's database: 1,080 jobs, 163 builds with all 260 PDFs, 78 applications, the master resume at version 650, integrity ok).
- Fetching is faster (807 catalog boards in 79 s against about 210 s for 599 before), and quiet boards rest, so later fetches take about 20 s.
- ADRs 001–018 cite sections of the first spec, now at [`../archive/SPEC-v1.md`](../archive/SPEC-v1.md).
