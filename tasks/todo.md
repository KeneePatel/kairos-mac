# Tasks: Kairos for macOS

Plan: `tasks/plan.md` · Spec: `SPEC.md` · Bar: `CONSTRAINTS.md`

**Shorthand used below:**
- `core-test X` = `swift test --package-path Packages/KairosCore --filter X`
- `app-build` = `xcodebuild -project App/Kairos.xcodeproj -scheme Kairos -destination 'platform=macOS,arch=arm64' build`
- `task-end checks` = the "Task end" rows of `CONSTRAINTS.md`: tests, changed-line coverage, floor guard, dependency check

**Every task that touches UI also:** reads `design/kairos/README.md` and the closest screen file first for the look and feel; uses only tokens (no raw colours); and ends with a written list of every remaining visual difference from that `.dc.html` file, with the reason for each. Features and content follow `SPEC.md`, even where a mockup shows something else. Screens: T14 Today and Sources (first pass) · T17–T18 `MasterResume` · T24 `SettingsAI` · T31 `Main` and `TodayDark` · T36 `Build` · T43 `Sources` · T44 `MenuBar` · T45 `Applications` · T51 `SignIn` · T58–T59 `PhoneToday` and `PhoneJob`.

**Done means:** the acceptance criteria are met, the verification passes, the task-end checks pass, and the commit follows `AGENTS.md`. Sizes: S = 1–2 files, M = 3–5 files.

---

## Phase 0: Foundation and risk spikes

- [x] **T01 · Repository bootstrap** (S) · deps: none · your step: create the GitHub repo
  - **What:** turn `kairos-mac/` into a git repo with your identity and the public-repo basics.
  - **Acceptance:**
    - [ ] `git config user.name` and `user.email` are set to Kenee Patel, and the first commit has no trailers.
    - [ ] `LICENSE` is MIT. `README.md` explains the project and credits the original Kairos (github.com/sneh2102/Kairos).
    - [ ] `CONTRIBUTING.md` (pull requests must pass CI) and `SECURITY.md` (how to report a vulnerability privately) exist. `.gitignore` covers `Vendor/`, `build/`, `.build/`, `*.xcuserdata` and `.env*`.
  - **Verify:** `git log -1 --format='%an <%ae> | %cn <%ce> | %(trailers)'`
  - **Files:** `.gitignore`, `LICENSE`, `README.md`, `CONTRIBUTING.md`, `SECURITY.md`

- [x] **T02 · Package skeleton with HLC and UUIDv7** (M) · deps: T01
  - **What:** create `Packages/KairosCore` (Swift 6 language mode, macOS 26) with a `Store` target and its first real code.
  - **Acceptance:**
    - [ ] `swift build` passes with warnings as errors; the package resolves zero dependencies.
    - [ ] HLC strings compare correctly as text, stay monotonic when the wall clock goes backwards, and absorb a received remote clock.
    - [ ] UUIDv7 ids sort by creation time and are RFC 9562 version 7.
  - **Verify:** `core-test StoreTests`
  - **Files:** `Packages/KairosCore/Package.swift`, `Sources/Store/HLC.swift`, `Sources/Store/UUIDv7.swift`, `Tests/StoreTests/HLCTests.swift`, `Tests/StoreTests/UUIDv7Tests.swift`

- [x] **T03 · Guard scripts and formatter config** (M) · deps: T02
  - **What:** the scripts `CONSTRAINTS.md` names, so every check is runnable.
  - **Acceptance:**
    - [ ] `scripts/floor-guard.swift` is the skill's reference contract adapted to Swift (`try!`, `fatalError` stubs, empty `catch {}`, `.disabled(` traits, `XCTSkip`, removed `#expect`/`#require`, suppressions, weakened `CONSTRAINTS.md` rows). It exits 0, 1 or 2 and never prints a secret value.
    - [ ] `check-deps.sh` fails on any resolved package, an unlisted bundled binary, or a `package.json` in `Web/`. `check-commits.sh` fails on a wrong author or committer, or any trailer. `coverage-diff.sh` reports changed-line coverage from `swift test --enable-code-coverage` output.
    - [ ] `.swift-format` enables `NeverForceUnwrap`, `NeverUseForceTry` and `NeverUseImplicitlyUnwrappedOptionals`, with tests excluded where needed.
  - **Verify:** run each script on the clean tree (exit 0). In a throwaway branch, plant a `try!` and a commit with a `Co-Authored-By` trailer: each must fail. Delete the branch.
  - **Files:** `scripts/floor-guard.swift`, `scripts/check-deps.sh`, `scripts/check-commits.sh`, `scripts/coverage-diff.sh`, `.swift-format`

- [ ] **T04 · CI workflow** (S) · deps: T03 · your step: push the repo to GitHub
  - **What:** `.github/workflows/ci.yml` runs on every pull request and every push to `main`.
  - **Acceptance:**
    - [ ] Runs format lint, build with warnings as errors, tests, changed-line coverage, floor guard, `check-deps`, `check-commits` and gitleaks (`--redact`).
    - [ ] Uses a GitHub-hosted macOS image with Xcode 26; the image label is confirmed and noted in the workflow.
    - [ ] A test branch with a planted violation goes red; `main` is green.
  - **Verify:** the GitHub Actions run results for both branches.
  - **Files:** `.github/workflows/ci.yml`

- [x] **T05 · App shell** (M) · deps: T02 · needs P1 decided (XcodeGen)
  - **What:** a SwiftUI app that links `KairosCore` and shows the final navigation.
  - **Acceptance:**
    - [ ] `App/project.yml` generates `App/Kairos.xcodeproj` with `xcodegen generate`.
    - [ ] A `NavigationSplitView` sidebar with Today, Jobs, Builds, Applications, Master resume, Sources, Settings and Activity (placeholders for now), styled after `Main.dc.html`. System materials only; no hand-drawn glass or window buttons.
    - [ ] App Sandbox entitlements: outgoing network and user-selected files. The `kairos://` URL scheme is registered, and `open kairos://ping` brings the app forward and logs the URL.
  - **Verify:** `app-build`; launch and check manually.
  - **Files:** `App/project.yml`, `App/Kairos/KairosApp.swift`, `App/Kairos/RootView.swift`, `App/Kairos/Kairos.entitlements`, `App/Kairos/Info.plist`

- [ ] **T05a · Design tokens, app icon, menu bar icon** (M) · deps: T05
  - **What:** turn `design/kairos/tokens.json` into code once, so no view ever holds a raw colour.
  - **Acceptance:**
    - [ ] `scripts/gen-tokens.swift` generates one Asset Catalog colour set per colour token (Any and Dark, keeping alpha for `rgba()` tokens) and `DesignTokens.swift` with the type styles, spacing and radii as named constants.
    - [ ] The app icon is built from `design/kairos/logo/` (Icon Composer layers, or the asset-catalog PNGs). `menubar-template.svg` is added as a template image.
    - [ ] `scripts/check-design.sh` fails on hex literals, `Color(red:` or `NSColor(` values in `App/`; it's wired into CI.
  - **Verify:** run the generator twice (no diff the second time); `scripts/check-design.sh`; `app-build`; the icon shows in the Dock and the menu bar.
  - **Files:** `scripts/gen-tokens.swift`, `scripts/check-design.sh`, `App/Kairos/Assets.xcassets/`, `App/Kairos/DesignTokens.swift`

- [ ] **T06 · Spike: Typst inside the sandboxed, self-signed app** (M) · deps: T05 · **high risk**
  - **What:** prove that the sandboxed app can run a bundled `typst` binary on JSON input and read the resulting PDF.
  - **Acceptance:**
    - [ ] `scripts/fetch-typst.sh` downloads a pinned release for `aarch64-apple-darwin` and verifies its SHA-256 into `Vendor/typst/`.
    - [ ] A `Render` target test compiles `spike.typ` from a JSON file; PDFKit finds the expected text and a page count of 1.
    - [ ] The same call works from the signed, sandboxed app (debug menu item). The bundle size is recorded in `CONSTRAINTS.md` → "Measured".
  - **Verify:** `core-test RenderTests`, plus the in-app run. Write-up in `docs/spikes/typst-sandbox.md`, with the fallback decision if it fails.
  - **Files:** `scripts/fetch-typst.sh`, `Sources/Render/TypstRunner.swift`, `Sources/Render/Templates/spike.typ`, `Tests/RenderTests/TypstRunnerTests.swift`, `docs/spikes/typst-sandbox.md`

- [ ] **T07 · Spike: Keychain access across self-signed rebuilds** (S) · deps: T05 · **risk**
  - **What:** confirm that a stable self-signed certificate keeps Keychain items readable after an update.
  - **Acceptance:**
    - [ ] The `Secrets` target stores and reads a test item with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.
    - [ ] Build A stores the item. Build B (with a code change, same certificate) reads it with no prompt.
    - [ ] Certificate creation steps are documented. No certificate or key material is committed.
  - **Verify:** manual A/B runs; write-up in `docs/spikes/keychain-signing.md`.
  - **Files:** `Sources/Secrets/Keychain.swift`, `Tests/SecretsTests/KeychainTests.swift`, `docs/spikes/keychain-signing.md`, `docs/signing.md`

- [ ] **T08 · Split the decision records into `docs/decisions/`** (S, docs only) · deps: T01
  - **What:** move SPEC Appendix A into one file per ADR (documentation-and-adrs), and leave an index in the spec.
  - **Acceptance:**
    - [ ] `docs/decisions/ADR-001-…md` through `ADR-014-…md`, each with Status, Date, Context, Decision, Alternatives and Consequences.
    - [ ] SPEC Appendix A becomes a linked index.
  - **Verify:** every link resolves (`grep` the index against `ls docs/decisions`).
  - **Files:** `docs/decisions/*` (14 small docs; mechanical, so an exception to the five-file guideline), `SPEC.md`

### Checkpoint A: Foundation
- [ ] CI green on `main`; all `CONSTRAINTS.md` commands run
- [ ] T06 and T07 write-ups reviewed with you; fallback decided if either failed

---

## Phase 1: R1 Local MVP

### Slice 1: Jobs in

- [ ] **T09 · SQLite wrapper and migrator** (M) · deps: T02
  - **What:** the thin wrapper over `import SQLite3` (ADR-002).
  - **Acceptance:**
    - [ ] Opens in WAL mode, runs prepared statements with bound parameters, and handles nested-safe transactions with rollback on error.
    - [ ] The migrator applies `Schema/NNN_*.sql` in order, tracks `PRAGMA user_version`, and refuses a database newer than the app.
    - [ ] Per-account layout (`Application Support/Kairos/<account>/kairos.sqlite`, with `local/` before sign-in). A startup check reports JSON1, FTS5 and STRICT support.
  - **Verify:** `core-test StoreTests`. Record project coverage in `CONSTRAINTS.md` → "Measured".
  - **Files:** `Sources/Store/Database.swift`, `Sources/Store/Statement.swift`, `Sources/Store/Migrator.swift`, `Sources/Store/AccountStore.swift`, `Tests/StoreTests/DatabaseTests.swift`

- [ ] **T10 · Jobs schema and repositories** (M) · deps: T09
  - **Acceptance:**
    - [ ] `001_sources_jobs.sql` creates `source`, `search`, `job` and `run` as STRICT tables, with `updated_hlc` and `deleted` on the synced ones (SPEC §6.2).
    - [ ] Repositories upsert jobs by id, tombstone instead of deleting, stamp HLC on every write, and query by state, verdict and country.
    - [ ] A job id is the hash of the canonical URL (the same input gives the same id).
  - **Verify:** `core-test StoreTests`
  - **Files:** `Sources/Store/Schema/001_sources_jobs.sql`, `Sources/Store/JobRepository.swift`, `Sources/Store/SourceRepository.swift`, `Tests/StoreTests/JobRepositoryTests.swift`

- [ ] **T11 · HTTP client and Greenhouse source** (M) · deps: T02
  - **Acceptance:**
    - [ ] `HTTPClient` protocol, a URLSession implementation, and a test `URLProtocol` that fails any request it wasn't scripted for (the no-network rule).
    - [ ] `JobSource` and `Posting` exactly as in SPEC §10. `GreenhouseSource` maps a recorded `boards-api.greenhouse.io` response.
    - [ ] Errors are typed (`SourceError`); a timeout and an HTTP 404 each map correctly.
  - **Verify:** `core-test JobSourcesTests`
  - **Files:** `Sources/JobSources/HTTPClient.swift`, `Sources/JobSources/JobSource.swift`, `Sources/JobSources/GreenhouseSource.swift`, `Tests/JobSourcesTests/GreenhouseSourceTests.swift`, `Tests/Fixtures/greenhouse_jobs.json`

- [ ] **T12 · Lever and Ashby sources, ATS detection** (M) · deps: T11
  - **Acceptance:**
    - [ ] `LeverSource` (`api.lever.co/v0/postings/{slug}?mode=json`) and `AshbySource` (`api.ashbyhq.com/posting-api/job-board/{org}`) map recorded responses.
    - [ ] `ATSDetector` turns a careers URL (boards.greenhouse.io, jobs.lever.co, jobs.ashbyhq.com, and embedded variants) into a source kind and slug, or returns a clear "not detected".
  - **Verify:** `core-test JobSourcesTests`
  - **Files:** `Sources/JobSources/LeverSource.swift`, `Sources/JobSources/AshbySource.swift`, `Sources/JobSources/ATSDetector.swift`, `Tests/JobSourcesTests/LeverAshbyTests.swift`, `Tests/Fixtures/lever_ashby.json`

- [ ] **T13 · Normalization, geography, de-duplication** (M) · deps: T11
  - **Acceptance:**
    - [ ] Canonical URLs drop tracking parameters. HTML descriptions become Markdown with a small converter (no WebKit, so it runs off the main thread).
    - [ ] Geography parses country (CA or US), province or state, city, and remote scope ("Remote – Canada", "Remote (US only)"). Covered by a 60-string table test.
    - [ ] De-duplication drops known ids and cross-board near-duplicates (company + title + city similarity ≥ 0.9).
  - **Verify:** `core-test JobSourcesTests`
  - **Files:** `Sources/JobSources/Normalizer.swift`, `Sources/JobSources/Geo/Geo.swift`, `Sources/JobSources/Geo/places.json`, `Sources/JobSources/Deduplicator.swift`, `Tests/JobSourcesTests/NormalizerGeoTests.swift`

- [ ] **T14 · First vertical slice in the app** (M) · deps: T10, T12, T13, T05
  - **Acceptance:**
    - [ ] `Pipeline.FetchRun` runs fetch → normalize → de-duplicate → store → `run` row. It's cancellable and reports progress as an `AsyncStream`.
    - [ ] The Sources screen adds a company by careers URL (with detection) and lists sources and their health.
    - [ ] The Jobs screen lists jobs with country and location; the detail view shows the Markdown description. "Fetch now" shows progress and can be stopped.
  - **Verify:** `core-test PipelineTests`, `app-build`. Manually: add 3 real companies and fetch.
  - **Files:** `Sources/Pipeline/FetchRun.swift`, `App/Kairos/AppModel.swift`, `App/Kairos/Screens/SourcesView.swift`, `App/Kairos/Screens/JobsView.swift`, `App/Kairos/Screens/JobDetailView.swift`

#### Checkpoint B
- [ ] 3 real companies fetched; duplicates removed; countries parsed; task-end checks green; reviewed with you

### Slice 2: Master resume, plus the LLM layer

- [ ] **T15 · Master resume schema, model, versioning** (M) · deps: T09
  - **Acceptance:**
    - [ ] `002_master_resume.sql` creates `resume_contact`, `resume_entry`, `resume_bullet` and `skill` (SPEC §6.2).
    - [ ] Swift model types for the contact block, every entry kind, bullets and skills (Proven or Can discuss).
    - [ ] Every save increments `master_version` in the same transaction; entry and bullet ids stay stable across edits.
  - **Verify:** `core-test MasterResumeTests`
  - **Files:** `Sources/Store/Schema/002_master_resume.sql`, `Sources/MasterResume/Model.swift`, `Sources/MasterResume/MasterResumeRepository.swift`, `Tests/MasterResumeTests/RepositoryTests.swift`

- [ ] **T16 · Master resume validation** (S, test-first) · deps: T15
  - **Acceptance:**
    - [ ] Required fields are enforced: name, email, phone, LinkedIn URL, total years, at least one experience bullet, at least 5 Proven skills.
    - [ ] Email format; phone normalized to E.164 with +1 by default; LinkedIn `https://www.linkedin.com/in/<handle>`; GitHub `https://github.com/<user>`; portfolio `https://…`.
    - [ ] `BuildReadiness` lists the missing items. A warning appears when total years disagrees with the experience dates by more than a year.
  - **Verify:** `core-test MasterResumeTests` (table-driven cases)
  - **Files:** `Sources/MasterResume/Validator.swift`, `Sources/MasterResume/PhoneNumber.swift`, `Tests/MasterResumeTests/ValidatorTests.swift`

- [ ] **T17 · Editor: contact, skills, additional sections** (M) · deps: T16, T05
  - **Acceptance:**
    - [ ] The contact form shows inline validation, and required fields are marked.
    - [ ] Skills: add, categorize, reorder, and toggle Proven / Can discuss.
    - [ ] Certifications, awards, volunteering, publications, languages (with proficiency) and custom sections are editable. Saving bumps the version shown in the header.
  - **Verify:** `app-build`; manual walkthrough; `core-test MasterResumeTests`
  - **Files:** `App/Kairos/MasterResume/MasterResumeView.swift`, `ContactSection.swift`, `SkillsSection.swift`, `AdditionalSections.swift`

- [ ] **T18 · Editor: experience, projects, education** (M) · deps: T17
  - **Acceptance:**
    - [ ] Entries: add, edit, reorder, delete with confirmation, and a "current" toggle for end dates.
    - [ ] Bullets: add, edit and reorder, with metrics and skills chips.
    - [ ] The Build readiness banner updates live.
  - **Verify:** `app-build`; manual walkthrough
  - **Files:** `App/Kairos/MasterResume/ExperienceSection.swift`, `ProjectsSection.swift`, `EducationSection.swift`, `BulletEditor.swift`

- [ ] **T19 · LLM core: tasks, schema validator, fake provider** (M, test-first) · deps: T02
  - **Acceptance:**
    - [ ] `LLMTask`, `ChatMessage`, `LLMResult` and `LLMError` as in SPEC §5.5.
    - [ ] `JSONSchema` value type and validator for the subset: object, array, string enums, integer ranges, required fields, max length, max items. Error messages name the failing path.
    - [ ] `FakeProvider` returns scripted replies per task id.
  - **Verify:** `core-test LLMTests`
  - **Files:** `Sources/LLM/LLMTask.swift`, `Sources/LLM/JSONSchema.swift`, `Sources/LLM/SchemaValidator.swift`, `Sources/LLM/FakeProvider.swift`, `Tests/LLMTests/SchemaValidatorTests.swift`

- [ ] **T20 · Spike: live structured output** (S) · deps: T19 · your step: a Gemini key (and optionally local Ollama)
  - **Acceptance:**
    - [ ] Opt-in live tests send a sample schema to Gemini's OpenAI-compatible endpoint (`response_format` with a JSON schema) and to Ollama `/v1` (JSON mode, and a schema attempt).
    - [ ] Real replies are captured as fixtures, with keys and personal data removed.
    - [ ] The write-up states each preset's capability flag.
  - **Verify:** `KAIROS_LIVE_LLM=1 core-test LiveStructuredOutput`; `docs/spikes/structured-output.md`
  - **Files:** `Tests/LLMTests/LiveStructuredOutputTests.swift`, `Tests/Fixtures/llm/*.json`, `docs/spikes/structured-output.md`

- [ ] **T21 · OpenAI-compatible adapter and presets** (M) · deps: T20
  - **Acceptance:**
    - [ ] Presets for Gemini, Ollama local, Ollama Cloud, Groq, OpenRouter and OpenAI, each with its base URL and capability flags (from T20).
    - [ ] Builds `chat/completions` requests (with `response_format` mode and `reasoning_effort` where supported), parses `usage`, and lists models with `GET /models`.
    - [ ] Maps 400, 401, 403, 404, 429 (with `Retry-After`) and 5xx to typed errors.
  - **Verify:** `core-test LLMTests` (recorded fixtures)
  - **Files:** `Sources/LLM/OpenAICompatibleProvider.swift`, `Sources/LLM/ProviderPreset.swift`, `Tests/LLMTests/OpenAICompatibleProviderTests.swift`

- [ ] **T22 · LLM client: rate limits, retries, key rotation, repair** (M, test-first) · deps: T21
  - **Acceptance:**
    - [ ] Token-bucket limiter (requests per minute) and a concurrency cap per provider. Retries: 3 with backoff and jitter for network errors and 5xx. 429 rotates keys and honors `Retry-After`. 4xx are never retried.
    - [ ] The output pipeline decodes (stripping code fences), validates against the schema, runs the task's check, and makes one repair call that includes the error.
    - [ ] Cancellation stops in-flight requests. All timing is tested with a fake clock.
  - **Verify:** `core-test LLMTests`
  - **Files:** `Sources/LLM/LLMClient.swift`, `Sources/LLM/RateLimiter.swift`, `Sources/LLM/OutputPipeline.swift`, `Tests/LLMTests/LLMClientTests.swift`

- [ ] **T23 · Router, budget, cache, call log** (M) · deps: T22, T07
  - **Acceptance:**
    - [ ] `003_llm_local.sql` creates the local-only `llm_call` and `llm_cache` tables. Router: task → provider and model, with a fallback chain.
    - [ ] The daily call budget pauses LLM steps with "Daily AI budget reached". The cache key is (task, input hash, prompt version, model).
    - [ ] Keys are read from the Keychain (`Secrets`), never from SQLite. Call log rows never contain prompt or response text.
  - **Verify:** `core-test LLMTests`
  - **Files:** `Sources/Store/Schema/003_llm_local.sql`, `Sources/LLM/LLMRouter.swift`, `Sources/LLM/Budget.swift`, `Sources/LLM/CallLog.swift`, `Tests/LLMTests/RouterBudgetTests.swift`

- [ ] **T24 · Settings: AI providers** (M) · deps: T23, T05
  - **Acceptance:**
    - [ ] Add a provider from a preset or a custom URL. Add keys (they form the pool); keys are stored in the Keychain and shown masked.
    - [ ] "Test" lists models through `GET /models`. Pick a model per task; set the fallback chain, requests per minute and daily budget.
    - [ ] The onboarding privacy note covers Gemini's free-tier data terms and offers local Ollama.
  - **Verify:** `app-build`; manual test with your key
  - **Files:** `App/Kairos/Settings/ProvidersView.swift`, `App/Kairos/Settings/ProviderEditor.swift`, `App/Kairos/Settings/TaskRoutingView.swift`

- [ ] **T25 · Import a resume into the master resume** (M) · deps: T24, T18
  - **Acceptance:**
    - [ ] Text comes from a PDF (PDFKit) or a paste. **Before anything is sent, code removes** the contact values already entered, plus anything shaped like an email, phone number or profile URL (test-first).
    - [ ] The `importResume` task (prompt v1, schema) returns a draft. The review screen accepts or edits each section; nothing is saved without confirmation.
    - [ ] Onboarding order: required contact fields first, then import.
  - **Verify:** `core-test MasterResumeTests` (redaction table tests); manual import of your real resume
  - **Files:** `Sources/MasterResume/ResumeTextExtractor.swift`, `Sources/MasterResume/ImportResumeTask.swift`, `App/Kairos/MasterResume/ImportReviewView.swift`, `Tests/MasterResumeTests/RedactionTests.swift`

- [ ] **T26 · Import GitHub repos as projects** (S) · deps: T25
  - **Acceptance:**
    - [ ] Lists the repos of your GitHub URL's user through the public REST API (optional token stored in the Keychain).
    - [ ] The `importGitHubRepo` task drafts a project entry from the repo name, languages and README excerpt; you review it before it's saved.
  - **Verify:** `core-test MasterResumeTests` (recorded GitHub responses); manual
  - **Files:** `Sources/MasterResume/GitHubImport.swift`, `Sources/MasterResume/ImportGitHubRepoTask.swift`, `Tests/MasterResumeTests/GitHubImportTests.swift`

#### Checkpoint C
- [ ] Your real resume imported into a valid master resume
- [ ] A redaction test shows no contact values in the import prompt
- [ ] Provider test works with your key; reviewed with you

### Slice 3: Screening

- [ ] **T27 · Prefilter rules** (M, test-first) · deps: T10, T13, T15
  - **Acceptance:**
    - [ ] Rules, in order: title include/exclude, seniority, years-required regex against your maximum, location and country policy, remote scope, work authorization, clearance, French, blacklist, posting age, already applied. The first failure is recorded with its rule id.
    - [ ] `004_private_settings.sql` creates the local-only `private_setting` table (work authorization, clearance). It's excluded from sync by design.
    - [ ] Table-driven tests: at least 5 cases per rule, including French-language postings and "Remote (US only)".
  - **Verify:** `core-test ScreeningTests`
  - **Files:** `Sources/Screening/Prefilter.swift`, `Sources/Screening/Rules.swift`, `Sources/Screening/YearsParser.swift`, `Sources/Store/Schema/004_private_settings.sql`, `Tests/ScreeningTests/PrefilterTests.swift`

- [ ] **T28 · Job analysis task** (M) · deps: T27, T23
  - **Acceptance:**
    - [ ] Posting cleanup removes boilerplate and truncates to budget, keeping requirements sections first.
    - [ ] The `analyzeJob` task (prompt v1, schema) receives only the posting plus skill names and languages. Output: requirements (must or nice, matched skill), years, seniority, domains, flags.
    - [ ] `005_screening.sql` creates `job_analysis` and `screening`; results are cached by prompt version.
  - **Verify:** `core-test ScreeningTests` (fake provider plus recorded replies)
  - **Files:** `Sources/Screening/PostingCleaner.swift`, `Sources/Screening/AnalyzeJobTask.swift`, `Sources/Screening/AnalysisRepository.swift`, `Sources/Store/Schema/005_screening.sql`, `Tests/ScreeningTests/AnalyzeJobTaskTests.swift`

- [ ] **T29 · Verdict and ranking** (S, test-first) · deps: T28
  - **Acceptance:**
    - [ ] The verdict comes from must-have and nice-to-have coverage, the years and level policy, authorization flags and thresholds, and the rule id is stored.
    - [ ] Ranking: verdict, then Canada before US, then match (success criterion S7).
  - **Verify:** `core-test ScreeningTests`
  - **Files:** `Sources/Screening/Verdict.swift`, `Sources/Screening/Ranking.swift`, `Tests/ScreeningTests/VerdictRankingTests.swift`

- [ ] **T30 · Screening pipeline** (M) · deps: T29, T14
  - **Acceptance:**
    - [ ] Fetch → normalize → de-duplicate → prefilter → analyze (rate-limited, cancellable) → verdict → rank, with progress events.
    - [ ] Run stats record the prefilter drop rate and the counts of new `yes` and `maybe` jobs.
    - [ ] Integration test with a fake source and a fake LLM.
  - **Verify:** `core-test PipelineTests`
  - **Files:** `Sources/Pipeline/ScreeningRun.swift`, `Sources/Pipeline/PipelineEvents.swift`, `Tests/PipelineTests/ScreeningRunTests.swift`

- [ ] **T31 · Today screen and verdict explanations** (M) · deps: T30, T17
  - **Acceptance:**
    - [ ] Today shows the ranked list with verdict and country chips and filters; Run and Stop show progress.
    - [ ] The job explanation shows requirements covered and missing, flags, and the deciding rule, and lets you overrule the verdict.
    - [ ] Settings has search preferences (titles, locations, countries in order) and work authorization (marked "stays on this Mac").
  - **Verify:** `app-build`; manual run on your watchlist
  - **Files:** `App/Kairos/Screens/TodayView.swift`, `App/Kairos/Screens/JobExplanationView.swift`, `App/Kairos/Settings/SearchPreferencesView.swift`, `App/Kairos/Settings/WorkAuthorizationView.swift`

#### Checkpoint D
- [ ] Real run on your watchlist; you review the verdicts; prefilter drop rate recorded (success criterion S6 baseline)

### Slice 4: Tailoring and rendering

- [ ] **T32 · Render pipeline and classic template** (M) · deps: T06, T15
  - **Acceptance:**
    - [ ] `TypstRunner` is hardened: timeout, error capture, `--ignore-system-fonts`, bundled fonts.
    - [ ] `classic.typ` reads resume JSON; the header comes from the contact block; section order and visibility are inputs.
    - [ ] A golden test checks the PDF text and page count for a fixture resume.
  - **Verify:** `core-test RenderTests`
  - **Files:** `Sources/Render/TypstRunner.swift`, `Sources/Render/ResumeDocument.swift`, `Sources/Render/Templates/classic.typ`, `Sources/Render/Fonts/` (open-licensed), `Tests/RenderTests/ClassicTemplateTests.swift`

- [ ] **T33 · Entry selection and strict verifier** (M, test-first) · deps: T29, T15
  - **Acceptance:**
    - [ ] The selector scores bullets and projects by requirement overlap (keywords, `Synonyms.json`, recency).
    - [ ] The strict verifier enforces `source_ids` existence, technologies and numbers from the cited bullets, years, and every hard limit (SPEC §5.3).
    - [ ] The 30-job fixture suite scaffold exists; violations are reported with the bullet and rule.
  - **Verify:** `core-test VerifierSuite`
  - **Files:** `Sources/Tailoring/Selector.swift`, `Sources/Tailoring/Verifier.swift`, `Sources/Tailoring/Synonyms.json`, `Tests/TailoringTests/VerifierSuite.swift`, `Tests/Fixtures/tailoring/`

- [ ] **T34 · Section writers and polish** (M) · deps: T33, T23
  - **Acceptance:**
    - [ ] Writer tasks for summary, skills, experience and projects (prompt v1, schemas with `source_ids`). They receive only the selected entries.
    - [ ] Polish swaps AI-sounding phrases, de-duplicates opening verbs, enforces length, and applies en-CA or en-US spelling by job country.
  - **Verify:** `core-test TailoringTests`
  - **Files:** `Sources/Tailoring/WriteSectionTasks.swift`, `Sources/Tailoring/Polish.swift`, `Sources/Tailoring/Spelling/en-CA.json`, `Sources/Tailoring/Spelling/en-US.json`, `Tests/TailoringTests/PolishTests.swift`

- [ ] **T35 · Match score, rewrite loop, build queue** (M) · deps: T34, T32
  - **Acceptance:**
    - [ ] Match score uses the SPEC §5.3 weights. Sections under 70 get `rewriteSection`, at most 3 passes, keeping the best version. Page fitting drops the lowest-ranked bullets.
    - [ ] `006_builds.sql` creates `build` and `artifact`; builds record `master_version` and mode.
    - [ ] The build queue (2 workers) resumes a crashed build from cached steps.
  - **Verify:** `core-test TailoringTests`, `core-test PipelineTests`
  - **Files:** `Sources/Tailoring/MatchScore.swift`, `Sources/Tailoring/BuildLoop.swift`, `Sources/Pipeline/BuildQueue.swift`, `Sources/Store/Schema/006_builds.sql`, `Tests/TailoringTests/BuildLoopTests.swift`

- [ ] **T36 · Build screen** (M) · deps: T35, T31
  - **Acceptance:**
    - [ ] Build is blocked until the master resume is ready (success criterion S14). Mode picker: strict or lite (stretch appears only when it's on).
    - [ ] Progress, PDF preview (PDFKit), and a bullet trace linking each bullet to its master-resume entries.
    - [ ] "Built from version N" note; Reveal in Finder; export.
  - **Verify:** `app-build`; manual strict build on a real job
  - **Files:** `App/Kairos/Screens/BuildView.swift`, `App/Kairos/Screens/PDFPreview.swift`, `App/Kairos/Screens/BulletTraceView.swift`

- [ ] **T37 · Stretch mode** (M) · deps: T36
  - **Acceptance:**
    - [ ] Settings toggle, off by default, with an explanation of what changes.
    - [ ] The `gapBullets` task is limited to Can-discuss skills and a per-role count of 0–2. Stretch verifier rules apply, and hard limits still hold.
    - [ ] Gap bullets are stored `verified: false`, highlighted in the trace, and listed under "Be ready to discuss"; nothing marks them in the PDF.
  - **Verify:** `core-test VerifierSuite` (stretch cases: 0 hard-limit violations, 100% flagged)
  - **Files:** `Sources/Tailoring/GapBulletsTask.swift`, `Sources/Tailoring/Verifier.swift`, `App/Kairos/Settings/StretchModeView.swift`, `App/Kairos/Screens/ReadyToDiscussView.swift`

- [ ] **T38 · Lite mode and cover letter** (M) · deps: T36
  - **Acceptance:**
    - [ ] Lite mode copies the selected bullets word for word; only the summary and skills are written.
    - [ ] The `coverLetter` task returns paragraphs as JSON; the verifier checks its claims; code adds the greeting, name and contact line; `cover.typ` renders it.
  - **Verify:** `core-test TailoringTests`; manual lite build and cover letter
  - **Files:** `Sources/Tailoring/LiteBuild.swift`, `Sources/Tailoring/CoverLetterTask.swift`, `Sources/Render/Templates/cover.typ`, `Tests/TailoringTests/CoverLetterTests.swift`

- [ ] **T39 · Prompt privacy tests and eval harness** (M) · deps: T38
  - **Acceptance:**
    - [ ] `PromptPrivacyTests` renders every task's prompt for a fixture user and fails if any contact value or private setting appears.
    - [ ] `PromptEvals` (opt-in live) has 30 labelled postings and reports must-have precision and recall and the first-write verifier pass rate to `evals/<date>-<model>.json`.
    - [ ] The first baseline report is committed and meets the `CONSTRAINTS.md` thresholds, or the gap is raised with you.
  - **Verify:** `core-test PromptPrivacyTests`; `KAIROS_LIVE_LLM=1 core-test PromptEvals`
  - **Files:** `Tests/LLMTests/PromptPrivacyTests.swift`, `Tests/LLMTests/PromptEvals.swift`, `Tests/Fixtures/evals/`, `evals/README.md`

### Checkpoint E: R1 exit
- [ ] Stories 4, 5 and 8 pass; success criteria S8, S9, S14 and S15 (privacy half) pass
- [ ] You review a week of sample builds; Phase 2 tasks refined together

---

## Phase 2: R2 Daily driver (refined at Checkpoint E)

- [ ] **T40 · Adzuna source, Canada first** (S) · deps: R1
  - **Acceptance:** queries `ca` before `us`; the key is in the Keychain; stays under the documented limits.
  - **Verify:** `core-test JobSourcesTests`

- [ ] **T41 · WebKit page runner and Indeed Canada** (M) · deps: R1
  - **Acceptance:** offscreen `WKWebView`, a data store per source, a JavaScript extractor contract, timeouts and health tracking. The Indeed Canada extractor passes on saved HTML fixtures.
  - **Verify:** `core-test JobSourcesTests`; manual run

- [ ] **T42 · LinkedIn, Job Bank and Indeed US extractors** (M) · deps: T41
  - **Acceptance:** one fixture test each; a board goes "degraded" after 3 empty runs.
  - **Verify:** `core-test JobSourcesTests`

- [ ] **T43 · Opt-in and login sheets for page-runner boards** (S) · deps: T41
  - **Acceptance:** the warning appears before opting in; login happens in a visible WebKit sheet; cookies persist per board. Styled after the opt-in section of `Sources.dc.html`.
  - **Verify:** `app-build`; manual

- [ ] **T44 · Scheduler, menu bar, login item, notifications** (M) · deps: R1
  - **Acceptance:** a daily run at the set time while the menu bar app runs; launch at login; one notification with yes and maybe counts.
  - **Verify:** `app-build`; manual over two days

- [ ] **T45 · Application tracking** (M) · deps: R1
  - **Acceptance:** `007_applications.sql`; status board; append-only timeline; notes; follow-up reminders as notifications.
  - **Verify:** `core-test StoreTests`; `app-build`

- [ ] **T46 · Retention and `kairos doctor`** (S) · deps: T45
  - **Acceptance:** archive after 60 days and tombstone after 120 for jobs never shortlisted; integrity checks report orphans.
  - **Verify:** `core-test StoreTests`

### Checkpoint F: R2 exit
- [ ] A week of daily use; stories 3 and 6 pass; Phase 3 refined

---

## Phase 3: R3 Accounts and sync (refined at Checkpoint F)

- [ ] **T47 · Backend migrations on staging** (M) · your step: create the staging project in Canada Central and link the CLI
  - **Acceptance:** `0001_sync`, `0002_invites` (hook plus mark-used trigger), `0003_account` (`delete_my_account`, `storage_usage`) and `0004_storage` applied with `supabase db push`. `Backend/AUTH_SETTINGS.md` written.
  - **Verify:** `supabase db push --workdir Backend` against staging

- [ ] **T48 · Backend isolation tests** (M) · deps: T47
  - **Acceptance:** with two disposable users, neither can read or write the other's rows or objects; a non-invited sign-up is rejected; deletion leaves nothing behind (success criteria S2–S4).
  - **Verify:** `KAIROS_LIVE_SUPABASE=1 core-test BackendIsolation`

- [ ] **T49 · Auth client** (M) · deps: T48
  - **Acceptance:** sign-up, password sign-in, proactive refresh, recover, and logout (local or global). The session is stored in the Keychain. Fake-server tests, including the 401 → refresh → sign-out path.
  - **Verify:** `core-test AccountTests`

- [ ] **T50 · OAuth with PKCE (Google, GitHub)** (M) · deps: T49
  - **Acceptance:** endpoint and parameter names verified against the supabase/auth source and recorded in the task notes first. `ASWebAuthenticationSession` handles the `kairos://auth/callback`, `confirm` and `reset` routes.
  - **Verify:** `core-test AccountTests`; manual against staging

- [ ] **T51 · Account screens and per-account databases** (M) · deps: T50
  - **Acceptance:** sign-up, sign-in and reset screens; Account screen (sign out, sign out everywhere, admin-only invite field); switching database per account; adopting local data on first sign-in.
  - **Verify:** `app-build`; manual

- [ ] **T52 · Sync push and pull** (M) · deps: T51
  - **Acceptance:** `008_sync_local.sql` (outbox triggers, sync state); push through `sync_push`; pull over REST; clock update on receipt; watermark. Convergence tests with a fake remote.
  - **Verify:** `core-test SyncTests`

- [ ] **T53 · Sync of PDFs, restore, command queue** (M) · deps: T52
  - **Acceptance:** PDFs uploaded to and downloaded from Storage; restore on a clean Mac matches content hashes (success criterion S5); "Sync paused" handling; command executor.
  - **Verify:** `core-test SyncTests`; manual restore

- [ ] **T54 · Account deletion and data export** (S) · deps: T53
  - **Acceptance:** order is Storage objects → `delete_my_account()` → local wipe. Export writes JSON per table plus PDFs to a folder.
  - **Verify:** `KAIROS_LIVE_SUPABASE=1 core-test BackendIsolation`

- [ ] **T55 · CLI** (S) · deps: T53
  - **Acceptance:** `kairos signin`, `scrape`, `build`, `sync --once` and `doctor` work headless (API sources only).
  - **Verify:** run each command against staging

- [ ] **T56 · Production setup and first invite** (S, your steps with a checklist)
  - **Acceptance:** production project in Canada Central; Brevo SMTP; Google and GitHub OAuth apps; redirect URLs; you added to `app_admin`; isolation tests green before `db push`; first friend invited and onboarded.
  - **Verify:** the checklist in `Backend/AUTH_SETTINGS.md` is fully ticked

### Checkpoint G: R3 exit
- [ ] Success criteria S2–S5 and S12 pass; first friend onboarded; Phase 4 refined

---

## Phase 4: R4 Release and companion (refined at Checkpoint G)

- [ ] **T57 · Release workflow and update check** (M) · your step: add the signing certificate as an encrypted repo secret
  - **Acceptance:** `release.yml` on a `v*` tag builds, signs, makes the DMG and publishes a GitHub Release. The app checks the GitHub Releases API for updates. The install guide covers "Open Anyway", with screenshots.
  - **Verify:** tag a pre-release; install it on a second Mac

- [ ] **T58 · PWA shell, sign-in and data pull** (M) · deps: R3
  - **Acceptance:** no framework and no npm packages; password sign-in and PKCE via WebCrypto; pull into IndexedDB; a service worker for the offline shell; data shown with `textContent` only.
  - **Verify:** `python3 -m http.server 8080 --directory Web`; manual

- [ ] **T59 · PWA screens** (M) · deps: T58
  - **Acceptance:** Today list, job detail, verdict override, queue a build, open a PDF (signed URL), application status.
  - **Verify:** manual checklist, plus a browser-testing-with-devtools pass

- [ ] **T60 · PWA deploy and browser check** (S) · deps: T59, T57
  - **Acceptance:** `release.yml` deploys `Web/` to GitHub Pages; the Pages origin is in the Supabase redirect allowlist; a build queued from a phone is picked up by the Mac.
  - **Verify:** live check from a phone

### Checkpoint H: R4 exit
- [ ] Story 2 works in a phone browser; queueing a build from the phone works end to end
