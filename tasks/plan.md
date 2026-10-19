# Implementation Plan: Kairos for macOS

**Status:** Approved 2026-10-19. In progress: Phase 0.
**Spec:** `SPEC.md` (draft, awaiting final approval) · **Look and feel:** `design/kairos/README.md` · **Quality bar:** `CONSTRAINTS.md` · **Tasks:** `tasks/todo.md`

## Overview

The plan builds the approved spec in four releases (SPEC §4):

| Release | Goal |
|---|---|
| R1 | Local MVP: master resume, screening, tailored PDFs |
| R2 | Daily driver: more sources, scheduler, application tracking |
| R3 | Accounts and Supabase sync |
| R4 | Signed releases and the PWA companion |

Work is cut into vertical slices: each slice ends with something usable in the app, not just a finished layer. Risky unknowns are tested first. Phase 0 runs two spikes that could change the design (Typst inside the sandbox, Keychain across self-signed builds) before anything depends on them.

Tasks for Phases 0 and 1 are fully specified. Tasks for Phases 2–4 have acceptance criteria but will be refined at the checkpoint before each phase, because R1 will teach us things that change them.

## Architecture decisions

The design decisions are SPEC Appendix A (ADR-001 to ADR-014). Three decisions belong to the plan itself and need your approval:

- **P1. Generate the Xcode project with XcodeGen** (a dev-only Homebrew tool, never shipped) from `App/project.yml`.
  - **Why:** an agent can't reliably hand-edit `project.pbxproj`, and the generated file causes merge conflicts in a public repo. A short YAML file is reviewable and reproducible in CI.
  - **Alternative:** create the project once by hand in Xcode and commit it. That means zero tools, but every later target or setting change goes through the Xcode UI.
- **P2. Tasks live in `tasks/todo.md`.**
  - **Why:** it's the default that downstream skills expect, and it's versioned with the code.
  - **Option:** mirror tasks to GitHub Issues later, if outside contributors need them.
- **P3. Spikes before dependents.**
  - Phase 0 spikes: Typst in the sandbox (T06), Keychain identity across self-signed builds (T07).
  - Phase 1 spike: live structured output from Gemini and Ollama (T20).
  - If a spike fails, its fallback is decided at the next checkpoint, before dependent work starts. For example, if Typst can't run inside the sandbox, fall back to WebKit printing (ADR-004).

## Dependency graph

```
T01 repo ─ T02 package ─ T03 guards ─ T04 CI
              │
              ├─ T05 app shell ─ T06 Typst spike ─ T07 Keychain spike
              │
              └─ T09 SQLite wrapper
                    ├─ T10 jobs schema ─ T11–T13 sources ─ T14 first app slice
                    ├─ T15 master resume schema ─ T16 validation ─ T17–T18 editor
                    └─ T19 LLM core ─ T20 spike ─ T21 adapter ─ T22 client ─ T23 router ─ T24 settings
                                                                                  └─ T25–T26 import
                    T27 prefilter ─ T28 analysis ─ T29 verdict ─ T30 pipeline ─ T31 UI
                    T32 render ─ T33 verifier ─ T34 writers ─ T35 build loop ─ T36 build UI
                    T37 stretch · T38 lite + cover letter · T39 privacy + evals
R2: T40–T46 (sources, WebKit, scheduler, applications)       needs R1
R3: T47–T48 backend + isolation tests ─ T49–T51 account ─ T52–T53 sync ─ T54–T56
R4: T57 release workflow · T58–T60 PWA                         needs R3
```

## Task list

### Phase −1: Design (owner approval required)
- [x] D01 Design approved as the brand and visual guide: `design/kairos/` (2026-10-18)
- [x] D02 Platform decided: SwiftUI (2026-10-18)

### Phase 0: Foundation and risk spikes
- [ ] T01 Repository bootstrap
- [ ] T02 Package skeleton with HLC and UUIDv7
- [ ] T03 Guard scripts and formatter config
- [ ] T04 CI workflow
- [ ] T05 App shell
- [ ] T05a Design tokens, app icon, menu bar icon
- [ ] T06 Spike: Typst inside the sandboxed, self-signed app
- [ ] T07 Spike: Keychain access across self-signed rebuilds
- [ ] T08 Split the decision records into `docs/decisions/`

### Checkpoint A: Foundation
- [ ] CI green; every `CONSTRAINTS.md` check runs
- [ ] Spike write-ups reviewed with you; fallbacks decided if needed

### Phase 1: R1 Local MVP
**Slice 1: Jobs in**
- [ ] T09 SQLite wrapper and migrator
- [ ] T10 Jobs schema and repositories
- [ ] T11 HTTP client and Greenhouse source
- [ ] T12 Lever and Ashby sources, ATS detection
- [ ] T13 Normalization, geography, de-duplication
- [ ] T14 First vertical slice in the app

#### Checkpoint B: add 3 real companies, fetch, see de-duplicated jobs with countries

**Slice 2: Master resume, plus the LLM layer**
- [ ] T15 Master resume schema, model, versioning
- [ ] T16 Master resume validation
- [ ] T17 Editor: contact, skills, additional sections
- [ ] T18 Editor: experience, projects, education
- [ ] T19 LLM core: tasks, schema validator, fake provider
- [ ] T20 Spike: live structured output (Gemini, Ollama)
- [ ] T21 OpenAI-compatible adapter and presets
- [ ] T22 LLM client: rate limits, retries, key rotation, repair
- [ ] T23 Router, budget, cache, call log
- [ ] T24 Settings: AI providers
- [ ] T25 Import a resume into the master resume
- [ ] T26 Import GitHub repos as projects

#### Checkpoint C: your real resume imported into a valid master resume; no contact data in any prompt

**Slice 3: Screening**
- [ ] T27 Prefilter rules
- [ ] T28 Job analysis task
- [ ] T29 Verdict and ranking
- [ ] T30 Screening pipeline
- [ ] T31 Today screen and verdict explanations

#### Checkpoint D: real run on your watchlist; verdicts reviewed; prefilter drop rate recorded

**Slice 4: Tailoring and rendering**
- [ ] T32 Render pipeline and classic template
- [ ] T33 Entry selection and strict verifier
- [ ] T34 Section writers and polish
- [ ] T35 Match score, rewrite loop, build queue
- [ ] T36 Build screen
- [ ] T37 Stretch mode
- [ ] T38 Lite mode and cover letter
- [ ] T39 Prompt privacy tests and eval harness

### Checkpoint E: R1 exit
- [ ] Stories 4, 5 and 8 pass; success criteria S8, S9, S14 and S15 (privacy half) pass
- [ ] Phase 2 tasks refined with you

### Phase 2: R2 Daily driver
- [ ] T40 Adzuna source (Canada first)
- [ ] T41 WebKit page runner and Indeed Canada
- [ ] T42 LinkedIn, Job Bank and Indeed US extractors
- [ ] T43 Opt-in and login sheets for page-runner boards
- [ ] T44 Scheduler, menu bar, login item, notifications
- [ ] T45 Application tracking
- [ ] T46 Retention and `kairos doctor`

### Checkpoint F: R2 exit
- [ ] A week of real daily use; stories 3 and 6 pass; Phase 3 refined

### Phase 3: R3 Accounts and sync
- [ ] T47 Backend migrations on staging
- [ ] T48 Backend isolation tests
- [ ] T49 Auth client
- [ ] T50 OAuth with PKCE
- [ ] T51 Account screens and per-account databases
- [ ] T52 Sync push and pull
- [ ] T53 Sync of PDFs, restore, command queue
- [ ] T54 Account deletion and data export
- [ ] T55 CLI
- [ ] T56 Production setup and first invite (your steps)

### Checkpoint G: R3 exit
- [ ] S2–S5 and S12 pass; first friend onboarded; Phase 4 refined

### Phase 4: R4 Release and companion
- [ ] T57 Release workflow and update check
- [ ] T58 PWA shell, sign-in and data pull
- [ ] T59 PWA screens
- [ ] T60 PWA deploy and browser check

### Checkpoint H: R4 exit
- [ ] Story 2 works in a phone browser; queueing a build from the phone works

## Parallel work

- After T09, three tracks are independent and can run in parallel sessions: sources (T10–T13), master resume (T15–T16), and the LLM core (T19–T22).
- Backend work (T47–T48) doesn't depend on the app and could start any time after Phase 0. It's scheduled for R3 so the free Supabase project isn't consumed and left idle (paused) early.
- Must stay sequential: SQLite migrations (numbered files, one owner at a time), the verifier and the build loop, and backend migrations.

## Risks and mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| The sandboxed app can't execute the bundled Typst binary | High | T06 spike first; fallback is WebKit printing (ADR-004) |
| Self-signed builds still trigger Keychain prompts after updates | Medium | T07 spike; fallback is the file-based keychain with an access group, or a documented one-time re-grant |
| A provider's structured output doesn't honor our schema subset | Medium | T20 spike captures real replies; local validation and repair already planned |
| No GitHub-hosted runner image with Xcode 26 | Medium | Confirm in T04; fallback is running the core package tests on the newest available image and building the app locally |
| The master-resume editor turns into a large UI task | Medium | Split into T17 and T18; editing is plain forms, with no rich text |
| Scope creep in R1 (tier-C boards, sync) | Medium | Deferred to R2 and R3 by design; checkpoints review scope |

## Open questions

1. ~~P1: XcodeGen as a dev-only tool?~~ Approved 2026-10-19.
2. ~~GitHub repository~~ Answered: you create the repo and push when asked. That's needed at T04 (CI); T01 only creates the local repo.
3. ~~Mirror tasks to GitHub Issues?~~ Answered: no, `tasks/todo.md` only.
4. **New Phase 0 prerequisite:** design approval (D01) before T01.
