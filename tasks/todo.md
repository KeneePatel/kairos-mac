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

- [x] **T04 · CI workflow** (S) · deps: T03 · your step: push the repo to GitHub
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

- [x] **T05a · Design tokens, app icon, menu bar icon** (M) · deps: T05
  - **What:** turn `design/kairos/tokens.json` into code once, so no view ever holds a raw colour.
  - **Acceptance:**
    - [ ] `scripts/gen-tokens.swift` generates one Asset Catalog colour set per colour token (Any and Dark, keeping alpha for `rgba()` tokens) and `DesignTokens.swift` with the type styles, spacing and radii as named constants.
    - [ ] The app icon is built from `design/kairos/logo/` (Icon Composer layers, or the asset-catalog PNGs). `menubar-template.svg` is added as a template image.
    - [ ] `scripts/check-design.sh` fails on hex literals, `Color(red:` or `NSColor(` values in `App/`; it's wired into CI.
  - **Verify:** run the generator twice (no diff the second time); `scripts/check-design.sh`; `app-build`; the icon shows in the Dock and the menu bar.
  - **Files:** `scripts/gen-tokens.swift`, `scripts/check-design.sh`, `App/Kairos/Assets.xcassets/`, `App/Kairos/DesignTokens.swift`

- [x] **T06 · Spike: Typst inside the sandboxed, self-signed app** (M) · deps: T05 · **high risk**
  - **What:** prove that the sandboxed app can run a bundled `typst` binary on JSON input and read the resulting PDF.
  - **Acceptance:**
    - [ ] `scripts/fetch-typst.sh` downloads a pinned release for `aarch64-apple-darwin` and verifies its SHA-256 into `Vendor/typst/`.
    - [ ] A `Render` target test compiles `spike.typ` from a JSON file; PDFKit finds the expected text and a page count of 1.
    - [ ] The same call works from the signed, sandboxed app (debug menu item). The bundle size is recorded in `CONSTRAINTS.md` → "Measured".
  - **Verify:** `core-test RenderTests`, plus the in-app run. Write-up in `docs/spikes/typst-sandbox.md`, with the fallback decision if it fails.
  - **Files:** `scripts/fetch-typst.sh`, `Sources/Render/TypstRunner.swift`, `Sources/Render/Templates/spike.typ`, `Tests/RenderTests/TypstRunnerTests.swift`, `docs/spikes/typst-sandbox.md`

- [x] **T07 · Spike: Keychain access across self-signed rebuilds** (S) · deps: T05 · **risk**
  - **What:** confirm that a stable self-signed certificate keeps Keychain items readable after an update.
  - **Acceptance:**
    - [ ] The `Secrets` target stores and reads a test item with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.
    - [ ] Build A stores the item. Build B (with a code change, same certificate) reads it with no prompt.
    - [ ] Certificate creation steps are documented. No certificate or key material is committed.
  - **Verify:** manual A/B runs; write-up in `docs/spikes/keychain-signing.md`.
  - **Files:** `Sources/Secrets/Keychain.swift`, `Tests/SecretsTests/KeychainTests.swift`, `docs/spikes/keychain-signing.md`, `docs/signing.md`

- [x] **T08 · Split the decision records into `docs/decisions/`** (S, docs only) · deps: T01
  - **What:** move SPEC Appendix A into one file per ADR (documentation-and-adrs), and leave an index in the spec.
  - **Acceptance:**
    - [ ] `docs/decisions/ADR-001-…md` through `ADR-014-…md`, each with Status, Date, Context, Decision, Alternatives and Consequences.
    - [ ] SPEC Appendix A becomes a linked index.
  - **Verify:** every link resolves (`grep` the index against `ls docs/decisions`).
  - **Files:** `docs/decisions/*` (14 small docs; mechanical, so an exception to the five-file guideline), `SPEC.md`

### Checkpoint A: Foundation (passed 2026-10-19)
- [x] CI green on `main`; all `CONSTRAINTS.md` commands run; a pull request with a planted `try!` went red
- [x] T06 and T07 write-ups reviewed with you; both spikes passed, no fallback needed

---

## Phase 1: R1 Local MVP

### Slice 1: Jobs in

- [x] **T09 · SQLite wrapper and migrator** (M) · deps: T02
  - **What:** the thin wrapper over `import SQLite3` (ADR-002).
  - **Acceptance:**
    - [x] Opens in WAL mode, runs prepared statements with bound parameters, and handles nested-safe transactions with rollback on error.
    - [x] The migrator applies `Schema/NNN_*.sql` in order, tracks `PRAGMA user_version`, and refuses a database newer than the app.
    - [x] Per-account layout (`Application Support/Kairos/<account>/kairos.sqlite`, with `local/` before sign-in). A startup check reports JSON1, FTS5 and STRICT support.
  - **Verify:** `core-test StoreTests`. Record project coverage in `CONSTRAINTS.md` → "Measured".
  - **Files:** `Sources/Store/Database.swift`, `Sources/Store/Statement.swift`, `Sources/Store/Migrator.swift`, `Sources/Store/AccountStore.swift`, `Tests/StoreTests/DatabaseTests.swift`
  - **Done 2026-10-19:** 38 Store tests pass (plus `MigratorTests`, `AccountStoreTests`). System SQLite 3.54.0 has JSON1, STRICT and FTS5. Changed-line coverage 94.7%; project 87.2%.

- [x] **T10 · Jobs schema and repositories** (M) · deps: T09
  - **Acceptance:**
    - [x] `001_sources_jobs.sql` creates `source`, `search`, `job` and `run` as STRICT tables, with `updated_hlc` and `deleted` on the synced ones (SPEC §6.2).
    - [x] Repositories upsert jobs by id, tombstone instead of deleting, stamp HLC on every write, and query by state, verdict and country.
    - [x] A job id is the hash of the canonical URL (the same input gives the same id).
  - **Verify:** `core-test StoreTests`
  - **Files:** `Sources/Store/Schema/001_sources_jobs.sql`, `Sources/Store/JobRepository.swift`, `Sources/Store/SourceRepository.swift`, `Tests/StoreTests/JobRepositoryTests.swift`
  - **Done 2026-10-19:** 63 Store tests pass. The HLC clock lives in the `Database` actor, so stamps follow commit order. Also added: `city` on `job` and `empty_runs` on `source` (SPEC §6.2 updated), the degraded-after-3-empty-runs rule, and `knownIDs` for the fetch de-duplication step.

- [x] **T11 · HTTP client and Greenhouse source** (M) · deps: T02
  - **Acceptance:**
    - [x] `HTTPClient` protocol, a URLSession implementation, and a test `URLProtocol` that fails any request it wasn't scripted for (the no-network rule).
    - [x] `JobSource` and `Posting` exactly as in SPEC §10. `GreenhouseSource` maps a recorded `boards-api.greenhouse.io` response.
    - [x] Errors are typed (`SourceError`); a timeout and an HTTP 404 each map correctly.
  - **Verify:** `core-test JobSourcesTests`
  - **Files:** `Sources/JobSources/HTTPClient.swift`, `Sources/JobSources/JobSource.swift`, `Sources/JobSources/GreenhouseSource.swift`, `Tests/JobSourcesTests/GreenhouseSourceTests.swift`, `Tests/Fixtures/greenhouse_jobs.json`
  - **Done 2026-10-19:** 11 JobSources tests pass. Checked against a live board: Greenhouse escapes `content` once, so the source decodes one level of entities; `postedAt` uses `first_published` (falls back to `updated_at`, which moves on every edit). Errors name host and path only, never the query, because Adzuna puts its key there. The fixture keeps the live shape with sample-company content.

- [x] **T12 · Lever and Ashby sources, ATS detection** (M) · deps: T11
  - **Acceptance:**
    - [x] `LeverSource` (`api.lever.co/v0/postings/{slug}?mode=json`) and `AshbySource` (`api.ashbyhq.com/posting-api/job-board/{org}`) map recorded responses.
    - [x] `ATSDetector` turns a careers URL (boards.greenhouse.io, jobs.lever.co, jobs.ashbyhq.com, and embedded variants) into a source kind and slug, or returns a clear "not detected".
  - **Verify:** `core-test JobSourcesTests`
  - **Files:** `Sources/JobSources/LeverSource.swift`, `Sources/JobSources/AshbySource.swift`, `Sources/JobSources/ATSDetector.swift`, `Tests/JobSourcesTests/LeverAshbyTests.swift`, `Tests/Fixtures/lever_ashby.json`
  - **Done 2026-10-19:** 19 JobSources tests pass. Fixtures are two files (`lever_postings.json`, `ashby_job_board.json`) because the shapes differ. Checked against live boards: Lever dates are epoch milliseconds and its requirements sit in `lists`, which are now folded into the description; Ashby unlisted jobs are skipped. `Posting` gained optional `otherLocations`, `countryHint` and `workplace` (defaults keep the SPEC §10 call valid) so T13 can use the boards' own location data; Ashby's secondary locations often add Canada.

- [x] **T13 · Normalization, geography, de-duplication** (M) · deps: T11
  - **Acceptance:**
    - [x] Canonical URLs drop tracking parameters. HTML descriptions become Markdown with a small converter (no WebKit, so it runs off the main thread).
    - [x] Geography parses country (CA or US), province or state, city, and remote scope ("Remote – Canada", "Remote (US only)"). Covered by a 60-string table test.
    - [x] De-duplication drops known ids and cross-board near-duplicates (company + title + city similarity ≥ 0.9).
  - **Verify:** `core-test JobSourcesTests`
  - **Files:** `Sources/JobSources/Normalizer.swift`, `Sources/JobSources/Geo/Geo.swift`, `Sources/JobSources/Geo/places.json`, `Sources/JobSources/Deduplicator.swift`, `Tests/JobSourcesTests/NormalizerGeoTests.swift`
  - **Done 2026-10-19:** 35 JobSources tests (the geography table has 74 strings, and a planted wrong row fails it). Postings outside Canada and the US come back as `.outsideCanadaAndUS` for the fetch to drop (SPEC §5.4). `RemoteScope` gained `remote` for "Remote" with no region. Near-duplicates are compared only within one company and across different sources; two URLs on one board are always two jobs.

- [x] **T14 · First vertical slice in the app** (M) · deps: T10, T12, T13, T05
  - **Acceptance:**
    - [x] `Pipeline.FetchRun` runs fetch → normalize → de-duplicate → store → `run` row. It's cancellable and reports progress as an `AsyncStream`.
    - [x] The Sources screen adds a company by careers URL (with detection) and lists sources and their health.
    - [x] The Jobs screen lists jobs with country and location; the detail view shows the Markdown description. "Fetch now" shows progress and can be stopped.
  - **Verify:** `core-test PipelineTests`, `app-build`. Manually: add 3 real companies and fetch.
  - **Files:** `Sources/Pipeline/FetchRun.swift`, `App/Kairos/AppModel.swift`, `App/Kairos/Screens/SourcesView.swift`, `App/Kairos/Screens/JobsView.swift`, `App/Kairos/Screens/JobDetailView.swift`
  - **Done 2026-10-19:** 7 Pipeline tests (fakes against real SQLite: storing, drops, failures counting as empty runs, the concurrency cap, cancellation); app builds clean. Live smoke (`KAIROS_LIVE=1 swift test --filter LiveSmokeTests`) on GitLab (Greenhouse), Spotify (Lever) and Ramp (Ashby): 481 found, 171 dropped as outside Canada and the US (all checked by hand: none Canadian or American), 310 stored, 304 with a country; the other 6 say only "Remote". The in-app run with 3 companies is for Checkpoint B with you.
  - **Visual differences from the mockups** (CLAUDE.md, Design):
    - Jobs vs `Main.dc.html`: no verdict filter, verdict or match columns, and the inspector shows posting facts and the description instead of score and requirements. Screening comes in T23–T26. Run status sits in the window subtitle (the native place on macOS 26) rather than as toolbar text, and the button says "Fetch now" (this task's wording) rather than "Run now". The Jobs section opens first because Today needs verdicts. No account footer in the sidebar until accounts exist (T27+).
    - Sources vs `Sources.dc.html`: no "Locations kept" column, opt-in boards section or titles-and-countries side panel; these belong to the prefilter settings and tier-C boards, which come later. "Can't reach" puts the reason in a tooltip rather than inline. Pause and Remove are in the row's context menu.
    - Not drawn in the design and decided here: empty states (system `ContentUnavailableView`), the Add company sheet (system form; the detected board shows as a green check and words), and the status "No jobs in N checks" for a degraded board (error colour, triangle icon and words, like "Can't reach").

#### Checkpoint B (passed 2026-10-19)
- [x] 3 real companies fetched; duplicates removed; countries parsed; task-end checks green; reviewed with you
  - Your review found one issue: in the Add company sheet the careers-page placeholder sat beside its label, so the field didn't read as a box to paste into. Fixed: labels above full-width bordered fields, the cursor starts in the careers field, and Return adds.

### Slice 2: Master resume, plus the LLM layer

- [x] **T15 · Master resume schema, model, versioning** (M) · deps: T09
  - **Acceptance:**
    - [x] `002_master_resume.sql` creates `resume_contact`, `resume_entry`, `resume_bullet` and `skill` (SPEC §6.2).
    - [x] Swift model types for the contact block, every entry kind, bullets and skills (Proven or Can discuss).
    - [x] Every save increments `master_version` in the same transaction; entry and bullet ids stay stable across edits.
  - **Verify:** `core-test MasterResumeTests`
  - **Files:** `Sources/Store/Schema/002_master_resume.sql`, `Sources/MasterResume/Model.swift`, `Sources/MasterResume/MasterResumeRepository.swift`, `Tests/MasterResumeTests/RepositoryTests.swift`
  - **Done 2026-10-19:** 18 MasterResume tests. Edits are small operations (save header, save entries, delete, reorder, skills), each one transaction with its own version bump, rather than one whole-document save: that would delete rows another device added since the editor loaded, once sync exists. Bullets dropped from an entry are tombstoned, so builds that cited them can still say so. Dates are months (`YYYY-MM`); entry fields are typed per kind.

- [x] **T16 · Master resume validation** (S, test-first) · deps: T15
  - **Acceptance:**
    - [x] Required fields are enforced: name, email, phone, LinkedIn URL, total years, at least one experience bullet, at least 5 Proven skills.
    - [x] Email format; phone normalized to E.164 with +1 by default; LinkedIn `https://www.linkedin.com/in/<handle>`; GitHub `https://github.com/<user>`; portfolio `https://…`.
    - [x] `BuildReadiness` lists the missing items. A warning appears when total years disagrees with the experience dates by more than a year.
  - **Verify:** `core-test MasterResumeTests` (table-driven cases)
  - **Files:** `Sources/MasterResume/Validator.swift`, `Sources/MasterResume/PhoneNumber.swift`, `Tests/MasterResumeTests/ValidatorTests.swift`
  - **Done 2026-10-19:** written test-first (failed to compile, then passed); 38 MasterResume tests. Validation tidies common variants into the required form (`linkedin.com/in/x` → `https://www.linkedin.com/in/x`, `jordan.dev` → `https://jordan.dev`) rather than rejecting them, but refuses `http://` portfolios instead of upgrading them, since the site may not serve https. Phone numbers with an extension are refused rather than shortened. Overlapping jobs count once in the years check.

- [x] **T17 · Editor: contact, skills, additional sections** (M) · deps: T16, T05
  - **Acceptance:**
    - [x] The contact form shows inline validation, and required fields are marked.
    - [x] Skills: add, categorize, reorder, and toggle Proven / Can discuss.
    - [x] Certifications, awards, volunteering, publications, languages (with proficiency) and custom sections are editable. Saving bumps the version shown in the header.
  - **Verify:** `app-build`; manual walkthrough; `core-test MasterResumeTests`
  - **Files:** `App/Kairos/MasterResume/MasterResumeView.swift`, `ContactSection.swift`, `SkillsSection.swift`, `AdditionalSections.swift`
  - **Done 2026-10-19:** app builds clean; 43 MasterResume tests. Fields save on Return or when you leave them; a malformed value shows its fix below the field once you've moved on, and missing ones are listed in the readiness panel instead of shouting from an empty form. Skills reorder by drag (dropping on the other group switches Proven / Can discuss). Following the design ("Portfolio is left off until fixed"), a malformed GitHub or portfolio link no longer blocks a build; it's a warning, and the render step (T32) must leave such links off. Checked by rendering the real views offscreen in light and dark (`Kairos --render-snapshots`, debug builds only).
  - **Visual differences from `MasterResume.dc.html`:** no Experience section, bullet chips or "Numbers" count yet (T18); a field with an error keeps the system border instead of a red outline, with the message and icon under it; the subtitle shows the version number rather than "edited Oct 16"; no "Used in N resumes" counts until builds exist. Not drawn in the design and decided here: the additional sections as grouped rows with chevrons, the entry editor sheet, the skill popover, and empty-section captions ("Optional").

- [x] **T18 · Editor: experience, projects, education** (M) · deps: T17
  - **Acceptance:**
    - [x] Entries: add, edit, reorder, delete with confirmation, and a "current" toggle for end dates.
    - [x] Bullets: add, edit and reorder, with metrics and skills chips.
    - [x] The Build readiness banner updates live.
  - **Verify:** `app-build`; manual walkthrough
  - **Files:** `App/Kairos/MasterResume/ExperienceSection.swift`, `ProjectsSection.swift`, `EducationSection.swift`, `BulletEditor.swift`
  - **Done 2026-10-19:** app builds clean. One `EntrySection` view serves roles and projects (grouped under "Experience", as the design does) and education, so there are no separate Projects and Education files; the entry editor moved to `EntryEditor.swift`. Bullets keep their ids through every edit; blank bullets are dropped on save. Volunteering and custom entries take bullets too. Deleting asks first. Checked in light and dark with `--render-snapshots`.
  - **Visual differences from `MasterResume.dc.html`:** no "Used in N resumes" on bullets until builds exist (T35); the readiness panel doesn't count "bullets with a number" yet. Not drawn and decided here: the entry editor sheet (fields in a grid, month and year pickers, a switch for "I work here now") and the bullet editor (each bullet in a grouped box with removable metric and skill chips, and a menu to move or remove it).

- [x] **T19 · LLM core: tasks, schema validator, fake provider** (M, test-first) · deps: T02
  - **Acceptance:**
    - [x] `LLMTask`, `ChatMessage`, `LLMResult` and `LLMError` as in SPEC §5.5.
    - [x] `JSONSchema` value type and validator for the subset: object, array, string enums, integer ranges, required fields, max length, max items. Error messages name the failing path.
    - [x] `FakeProvider` returns scripted replies per task id.
  - **Verify:** `core-test LLMTests`
  - **Files:** `Sources/LLM/LLMTask.swift`, `Sources/LLM/JSONSchema.swift`, `Sources/LLM/SchemaValidator.swift`, `Sources/LLM/FakeProvider.swift`, `Tests/LLMTests/SchemaValidatorTests.swift`
  - **Done 2026-10-19:** written test-first; 19 LLM tests. The validator reports every issue in document order (up to 20), so the single repair call can quote them all. Unknown extra properties are ignored when validating but the exported schema says `additionalProperties: false`, which strict provider modes need. `LLMProvider` (one model call, nothing more) is the seam T21's adapters implement.

- [x] **T20 · Spike: live structured output** (S) · deps: T19 · your step: a Gemini key (and optionally local Ollama)
  - **Acceptance:**
    - [x] Opt-in live tests send a sample schema to Gemini's OpenAI-compatible endpoint (`response_format` with a JSON schema) and to Ollama `/v1` (JSON mode, and a schema attempt).
    - [x] Real replies are captured as fixtures, with keys and personal data removed.
    - [x] The write-up states each preset's capability flag.
  - **Verify:** `KAIROS_LIVE_LLM=1 core-test LiveStructuredOutput`; `docs/spikes/structured-output.md`
  - **Files:** `Tests/LLMTests/LiveStructuredOutputTests.swift`, `Tests/Fixtures/llm/*.json`, `docs/spikes/structured-output.md`
  - **Done 2026-10-19** (you ran Gemini; I ran Ollama `qwen3.5:4B`): see `docs/spikes/structured-output.md`. Gemini Flash-Lite passes in strict schema mode (half the tokens of JSON mode). Ollama refuses every `response_format` for this model with HTTP 501 but answers correctly with the schema in the prompt; with thinking on it takes about 100 s per posting. `RecordedRepliesTests` checks every saved reply offline: schema, precision and recall against hand labels, error shapes, and no keys. Second run: `gemini-flash-latest` is valid and correct in JSON mode, with 504 hidden thinking tokens counted only in `total_tokens`; its schema mode met a temporary 503, now the retryable-error fixture. You confirmed thinking off for local models.

- [x] **T21 · OpenAI-compatible adapter and presets** (M) · deps: T20
  - **Acceptance:**
    - [x] Presets for Gemini, Ollama local, Ollama Cloud, Groq, OpenRouter and OpenAI, each with its base URL and capability flags (from T20).
    - [x] Builds `chat/completions` requests (with `response_format` mode and `reasoning_effort` where supported), parses `usage`, and lists models with `GET /models`.
    - [x] Maps 400, 401, 403, 404, 429 (with `Retry-After`) and 5xx to typed errors.
    - [x] From T20: capability is per (provider, model). HTTP 501 "structured output is unavailable" (Ollama) resends once without `response_format` and remembers the model as prompt-only. Gemini errors arrive as an array (`[{"error":…}]`); both shapes parse. A 429 whose quota limit is 0 maps to "model not on your plan", not a rate limit. Model defaults use Google's `gemini-flash-latest` / `gemini-flash-lite-latest` aliases. Output tokens are `total − prompt` when that exceeds `completion_tokens` (Gemini Flash's hidden thinking).
  - **Verify:** `core-test LLMTests` (recorded fixtures)
  - **Files:** `Sources/LLM/OpenAICompatibleProvider.swift`, `Sources/LLM/ProviderPreset.swift`, `Tests/LLMTests/OpenAICompatibleProviderTests.swift`
  - **Done 2026-10-19:** 22 adapter, preset and transport tests, replaying T20's real replies. A model that refuses a structured-output mode (501, or a 400 about `response_format`) drops one level and the provider remembers it in `ModelCapabilities`, shared across keys so the refusal is paid once. Base URLs must be https unless local, so a key never goes out over plain http. The scripted URLProtocol moved to a shared `TestSupport` test target. Learned capabilities live in memory for now; T23/T24 can persist them with the provider settings.

- [x] **T22 · LLM client: rate limits, retries, key rotation, repair** (M, test-first) · deps: T21
  - **Acceptance:**
    - [x] Token-bucket limiter (requests per minute) and a concurrency cap per provider. Retries: 3 with backoff and jitter for network errors and 5xx. 429 rotates keys and honors `Retry-After`. 4xx are never retried.
    - [x] The output pipeline decodes (stripping code fences), validates against the schema, runs the task's check, and makes one repair call that includes the error.
    - [x] Cancellation stops in-flight requests. All timing is tested with a fake clock.
    - [x] From T20: 501 is never retried; no wait exceeds 60 s (a free-tier 429 asked for 14 hours); local providers get a longer timeout (180 s) and run with thinking off by default (`reasoning_effort: none`; your decision, 2026-10-19). 503 "high demand" is retried with backoff.
  - **Verify:** `core-test LLMTests`
  - **Files:** `Sources/LLM/LLMClient.swift`, `Sources/LLM/RateLimiter.swift`, `Sources/LLM/OutputPipeline.swift`, `Tests/LLMTests/LLMClientTests.swift`
  - **Done 2026-10-19:** written test-first; 23 client and rate-limiter tests on a virtual clock (every wait is recorded exactly and nothing actually waits). A 429 rests that key and moves to the next at once; when every key rests, the client waits for the first unless that's over 60 s. A model off one key's plan tries the other keys only. The repair call carries the original reply and a note quoting every problem; tokens from both calls count. Per-task timeouts were added in T23.

- [x] **T23 · Router, budget, cache, call log** (M) · deps: T22, T07
  - **Acceptance:**
    - [x] `003_llm_local.sql` creates the local-only `llm_call` and `llm_cache` tables. Router: task → provider and model, with a fallback chain.
    - [x] The daily call budget pauses LLM steps with "Daily AI budget reached". The cache key is (task, input hash, prompt version, model).
    - [x] Keys are read from the Keychain (`Secrets`), never from SQLite. Call log rows never contain prompt or response text.
  - **Verify:** `core-test LLMTests`
  - **Files:** `Sources/Store/Schema/003_llm_local.sql`, `Sources/LLM/LLMRouter.swift`, `Sources/LLM/Budget.swift`, `Sources/LLM/CallLog.swift`, `Tests/LLMTests/RouterBudgetTests.swift`
  - **Done 2026-10-19:** 19 router, budget, cache and setup tests on a real migrated database. `llm` now depends on `store` for its own two tables, as `master-resume` does (SPEC §4 updated). The router walks each task's chain, falling back on anything but cancellation or the budget; it logs one row per run with counts and codes only (a test checks no prompt or reply text lands there), serves repeats from the cache (rechecked, free, unlogged) and pauses at the daily call or token limit until midnight. `ProviderSetup` holds key names; keys are read from the Keychain only when a client is built. Per-task timeouts: 60 s for extraction, 120 s for writing and resume import; local providers keep 180 s.

- [x] **T24 · Settings: AI providers** (M) · deps: T23, T05
  - **Acceptance:**
    - [x] Add a provider from a preset or a custom URL. Add keys (they form the pool); keys are stored in the Keychain and shown masked.
    - [x] "Test" lists models through `GET /models`. Pick a model per task; set the fallback chain, requests per minute and daily budget.
    - [x] The onboarding privacy note covers Gemini's free-tier data terms and offers local Ollama.
  - **Verify:** `app-build`; manual test with your key
  - **Files:** `App/Kairos/Settings/ProvidersView.swift`, `App/Kairos/Settings/ProviderEditor.swift`, `App/Kairos/Settings/TaskRoutingView.swift`
  - **Done 2026-10-19:** app builds clean; checked in light and dark with `--render-snapshots`. Settings are the synced "llm" document in a new `setting` table (`004_settings.sql`); it names keys but never holds them, and keys go straight to the login Keychain and are only shown masked. "Test" and "Refresh" list a provider's models, keeping text models only: Gemini's 63 ids include image, speech and embedding models and agent products (`deep-research-preview`), so its list keeps `gemini-`/`gemma-` ids, aliases first and previews last. Each task gets a model and a fallback; the daily budget and each provider's requests per minute are editable. Onboarding doesn't exist yet, so the privacy note (Gemini's free-tier terms, Ollama as the private option, "Keep everything on this Mac") lives in this screen; T25's onboarding will show the same panel. **Your step:** add your Gemini key in Settings → AI providers and choose Test.
  - **Visual differences from `SettingsAI.dc.html`:** tasks are the SPEC catalog's ("Read job postings", "Write experience"…) rather than the mockup's ("Score match", "Check every claim"), with one daily budget instead of a cap per task (SPEC §5.5). Ollama's models show without sizes (the OpenAI-compatible list has none). No "Show the last request sent" (a debug view for later). The General, Schedule and Account tabs are placeholders.

- [x] **T25 · Import a resume into the master resume** (M) · deps: T24, T18
  - **Acceptance:**
    - [x] Text comes from a PDF (PDFKit) or a paste. **Before anything is sent, code removes** the contact values already entered, plus anything shaped like an email, phone number or profile URL (test-first).
    - [x] The `importResume` task (prompt v1, schema) returns a draft. The review screen accepts or edits each section; nothing is saved without confirmation.
    - [x] Onboarding order: required contact fields first, then import.
  - **Verify:** `core-test MasterResumeTests` (redaction table tests); manual import of your real resume
  - **Files:** `Sources/MasterResume/ResumeTextExtractor.swift`, `Sources/MasterResume/ImportResumeTask.swift`, `App/Kairos/MasterResume/ImportReviewView.swift`, `Tests/MasterResumeTests/RedactionTests.swift`
  - **Done 2026-10-19:** redaction written test-first (30 table cases and a whole resume); 13 more import tests, including the prompt-privacy test SPEC §5.5 asks for. Prompts are versioned resources (`LLM/Prompts/importResume.v1.md`, loaded by `PromptLibrary`). Your city isn't removed: it would strip every job location too. The import sheet shows exactly what gets sent, refuses to run until your name, email, phone and LinkedIn are filled in, and saves only what you tick; edits in review change the draft, not the master resume, and header text fills only empty fields. **Your step:** add your Gemini key in Settings, then Master resume → Import resume… with your real resume (Checkpoint C).
  - **Not drawn in the design and decided here:** the import sheet (choose a PDF or paste, a "What gets sent" disclosure with the redacted text, a review list with a checkbox and Edit… per entry and per skill chip).
  - **Fixed 2026-10-19 (you reported import failing):** Gemini refused the import in strict schema mode with a bare "Request contains an invalid argument". Bisected live: list item counts (`maxItems`) in a schema this size are the cause. Strict requests now leave counts out and Kairos checks them on the reply; details in `docs/spikes/structured-output.md`. Verified with a full live import on Flash-Lite (valid on the first call). Error messages now say why an import failed.

- [x] **T26 · Import GitHub repos as projects** (S) · deps: T25
  - **Acceptance:**
    - [x] Lists the repos of your GitHub URL's user through the public REST API (optional token stored in the Keychain).
    - [x] The `importGitHubRepo` task drafts a project entry from the repo name, languages and README excerpt; you review it before it's saved.
  - **Verify:** `core-test MasterResumeTests` (recorded GitHub responses); manual
  - **Files:** `Sources/MasterResume/GitHubImport.swift`, `Sources/MasterResume/ImportGitHubRepoTask.swift`, `Tests/MasterResumeTests/GitHubImportTests.swift`
  - **Done 2026-10-19:** 9 tests on recorded GitHub responses (sample persona). The README excerpt and description are redacted like a resume before anything is sent (a test checks the name, email and site don't survive); dates and the repo link come from GitHub, not the model; a repo pushed in the last three months counts as current. Your own repos list first, forks and archived last. A token is optional (Keychain `github.token`); the sheet asks for one only when GitHub's 60-an-hour limit is hit. Drafts go through the same review as resume import. **Your step:** Master resume → Import → From GitHub… (needs your GitHub URL in Contact and an AI key).

- [x] **T20a · Re-check spike T20's open items and report back** (S) · deps: T21, T22 · your step: one live run with your key
  - **Why:** you asked (2026-10-19) to note these and come back to them. Doing this after T21–T22 means the real adapter, not the spike harness, gets checked.
  - **Acceptance:**
    - [x] Gemini Flash (`gemini-flash-latest`) in strict schema mode: measured. Both runs so far hit a temporary 503 "high demand", so this cell of `docs/spikes/structured-output.md` is still empty. If schema mode keeps failing, the Gemini preset falls back to JSON mode.
    - [x] Ollama through the real adapter and client (2026-10-19): the 501 refusal was handled and the model learned as prompt-only on its own, thinking was off by default, valid output in 8.5 s on one call. It listed the job title as a requirement again, which T28's prompt rule fixes. The thinking-mode merge re-check moved to T28, where the prompt that fixes it is written.
    - [x] Hidden thinking tokens: confirm T21's usage parsing counts them (`total − prompt`) against a fresh Gemini Flash reply.
    - [x] Report the results to you, and update the write-up and fixtures.
  - **Done 2026-10-19** (your run): Flash in strict schema mode is valid and correct (2 calls: the client retried a failed first try); Flash-Lite in 0.85 s; hidden thinking counted (588 output tokens for about 96 shown). Results are in `docs/spikes/structured-output.md`. `scripts/live-llm.sh` now runs these tests with the key from your Keychain, so the key never has to be typed or shown.
  - **Verify:** `scripts/live-llm.sh` or `KAIROS_LIVE_LLM=1 GEMINI_API_KEY=… swift test --package-path Packages/KairosCore --filter LiveAdapter` (you run it: the real adapter and client, `LiveAdapterTests.swift`); `core-test LLMTests`

#### Checkpoint C
- [x] T20a's re-check reported to you
- [ ] Your real resume imported into a valid master resume
- [x] A redaction test shows no contact values in the import prompt (`ImportTests.noContactDetailReachesThePrompt`, `GitHubImportTests.nothingPersonalFromTheReadmeIsSent`)
- [ ] Provider test works with your key; reviewed with you

### Slice 3: Screening

- [ ] **T27 · Prefilter rules** (M, test-first) · deps: T10, T13, T15
  - **Acceptance:**
    - [ ] Rules, in order: title include/exclude, seniority, years-required regex against your maximum, location and country policy, remote scope, work authorization, clearance, French, blacklist, posting age, already applied. The first failure is recorded with its rule id.
    - [ ] `005_private_settings.sql` creates the local-only `private_setting` table (work authorization, clearance). It's excluded from sync by design.
    - [ ] Table-driven tests: at least 5 cases per rule, including French-language postings and "Remote (US only)".
  - **Verify:** `core-test ScreeningTests`
  - **Files:** `Sources/Screening/Prefilter.swift`, `Sources/Screening/Rules.swift`, `Sources/Screening/YearsParser.swift`, `Sources/Store/Schema/005_private_settings.sql`, `Tests/ScreeningTests/PrefilterTests.swift`

- [ ] **T28 · Job analysis task** (M) · deps: T27, T23
  - **Acceptance:**
    - [ ] Posting cleanup removes boilerplate and truncates to budget, keeping requirements sections first.
    - [ ] The `analyzeJob` task (prompt v1, schema) receives only the posting plus skill names and languages. Output: requirements (must or nice, matched skill), years, seniority, domains, flags.
    - [ ] `006_screening.sql` creates `job_analysis` and `screening`; results are cached by prompt version.
    - [ ] From T20/T20a: the prompt asks for one requirement per item (never several skills in one) and never the job title. Re-record Ollama `qwen3.5:4B` with thinking on and remove `RecordedRepliesTests`' known-issue marker if the merge is gone.
  - **Verify:** `core-test ScreeningTests` (fake provider plus recorded replies)
  - **Files:** `Sources/Screening/PostingCleaner.swift`, `Sources/Screening/AnalyzeJobTask.swift`, `Sources/Screening/AnalysisRepository.swift`, `Sources/Store/Schema/006_screening.sql`, `Tests/ScreeningTests/AnalyzeJobTaskTests.swift`

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
    - [ ] `007_builds.sql` creates `build` and `artifact`; builds record `master_version` and mode.
    - [ ] The build queue (2 workers) resumes a crashed build from cached steps.
  - **Verify:** `core-test TailoringTests`, `core-test PipelineTests`
  - **Files:** `Sources/Tailoring/MatchScore.swift`, `Sources/Tailoring/BuildLoop.swift`, `Sources/Pipeline/BuildQueue.swift`, `Sources/Store/Schema/007_builds.sql`, `Tests/TailoringTests/BuildLoopTests.swift`

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
  - **Acceptance:** `008_applications.sql`; status board; append-only timeline; notes; follow-up reminders as notifications.
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
  - **Acceptance:** `009_sync_local.sql` (outbox triggers, sync state); push through `sync_push`; pull over REST; clock update on receipt; watermark. Convergence tests with a fake remote.
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
