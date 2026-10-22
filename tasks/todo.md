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
  - **Prompt v2 (2026-10-19, you asked after the live import):** v1 turned a year alone into January, called a project's description its role ("open-source Go CLI") and left its tech empty. v2 asks for "YYYY" when the resume gives no month, a role only when one is stated, and every technology named for a project; it also takes a certification's issuer from its name. A year alone is still saved as January (the master resume stores months, SPEC §5.10), but review now marks those entries "Your resume gives only the year…" until you change their dates. Live on the sample resume: Flash-Lite gave no role, tech Go and Docker, issuer AWS; Ollama `qwen3.5:4B` the same except tech Go and "CLI". When a free daily quota is used up (Gemini's 429 says when it resets), the import now says so instead of "try again in a minute".

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

- [x] **T24a · Backup keys that take over when one runs out** (S) · deps: T22, T24 · you asked 2026-10-19
  - **Acceptance:**
    - [x] Settings takes several keys per provider: a primary plus backups, tried in order (SPEC §5.5, "together they form the rotation pool").
    - [x] A key that used up its quota (a 429 with a retry time) rests for that model until then, and every later operation skips it without spending a request. Other models on the same key keep working (Gemini counts quota per model).
    - [x] When every key is used up, the error says when the first is back, and the task's fallback model takes over if it has one.
    - [x] "Test" checks every key, not just the primary, and each key shows Works, Rejected or "Used up: <model>, back in about …".
  - **Verify:** `core-test LLMTests` (`KeyRestsTests`); `--render-snapshots` (AI settings)
  - **Done 2026-10-19:** Most of the pool already existed (T22 rotated on a 429, T24 stored backup keys), but each operation built a new client and forgot which keys were used up. Now one `KeyRests` per provider is shared by every router the app builds, keyed by Keychain account and model; all `SystemClock`s share one start, so clients agree on when a rest ends. Rests last for the session only: after a relaunch one quick 429 finds out again. The same sharing fixes `ModelCapabilities`, which the app also rebuilt for every operation. The add-key sheet says that Gemini counts quota per Google Cloud project, so a backup key adds requests only if it's from a different project.

#### Checkpoint C
- [x] T20a's re-check reported to you
- [x] Your real resume imported into a valid master resume (you, 2026-10-19, after the Gemini schema fix and prompt v2)
- [x] A redaction test shows no contact values in the import prompt (`ImportTests.noContactDetailReachesThePrompt`, `GitHubImportTests.nothingPersonalFromTheReadmeIsSent`)
- [x] Provider test works with your key; reviewed with you (you, 2026-10-19: "Test" listed 24 models)

### Slice 3: Screening

- [x] **T27 · Prefilter rules** (M, test-first) · deps: T10, T13, T15
  - **Acceptance:**
    - [x] Rules, in order: title include/exclude, seniority, years-required regex against your maximum, location and country policy, remote scope, work authorization, clearance, French, blacklist, posting age, already applied. The first failure is recorded with its rule id.
    - [x] `005_private_settings.sql` creates the local-only `private_setting` table (work authorization, clearance). It's excluded from sync by design.
    - [x] Table-driven tests: at least 5 cases per rule, including French-language postings and "Remote (US only)".
  - **Verify:** `core-test ScreeningTests`
  - **Files:** `Sources/Screening/Prefilter.swift`, `Sources/Screening/Rules.swift`, `Sources/Screening/YearsParser.swift`, `Sources/Store/Schema/005_private_settings.sql`, `Tests/ScreeningTests/PrefilterTests.swift`
  - **Done 2026-10-19:** test-first. 22 tests, 5 to 15 cases per rule (about 140 in all), with French-language postings, "bilingual", "Remote (US only)" and US-only residency, plus 3 tests for `private_setting`. `Prefilter.rejection(for:)` returns the first rule failed (`PrefilterRule` raw values are the stored ids) and a sentence for the job's "why". It records nothing yet: the `screening` table arrives in T28 (`006_screening.sql`). New module `Screening` (store, llm, master-resume, as SPEC §4 maps it). Your preferences are the synced "screening" setting (`SearchPreferences`); work authorization and clearance are `WorkProfile` in the new local-only `private_setting`; French comes from your master resume's languages. T31 adds the screens to edit them.
  - **Decided here (tell me if any should change):**
    - **Nothing is filtered until you set it.** Defaults: no title phrases, every level, no years limit, Canada and the US, remote allowed, no blocked companies, no age limit. A country whose authorization you haven't set never rejects a job.
    - **When a rule can't tell, the job stays in** (an AI call costs less than a missed job): no description, an unknown country or region, or years that aren't clearly about experience.
    - **Years:** the largest minimum among required mentions ("2+ years of Python. 6+ years overall" is 6), English and French. Sentences or sections marked preferred, nice to have, bonus or asset don't count, nor do "founded 12 years ago" or "after 1 year of service".
    - **Seniority** comes from title words: Staff, Principal, Lead, Senior/Sr, II and III, Intern and Co-op, Junior/Jr, New grad, Associate, Manager (not "Product manager", which is a role), Director/VP/Head of. A title naming no level passes.
    - **French:** "bilingual" counts as French in Canadian postings; French at conversational level or better in your master resume passes; a posting written mostly in French is out if you don't speak it.
    - **Clearance:** "able to obtain" one passes if you're a citizen there (or a permanent resident, for Canada's Reliability Status).
    - **Already applied:** same company (ignoring Inc, LLC and the like) and titles sharing at least 80% of their words, so "Senior Software Developer" isn't the "Software Developer" you applied to.

- [x] **T28 · Job analysis task** (M) · deps: T27, T23
  - **Acceptance:**
    - [x] Posting cleanup removes boilerplate and truncates to budget, keeping requirements sections first.
    - [x] The `analyzeJob` task (prompt v1, schema) receives only the posting plus skill names and languages. Output: requirements (must or nice, matched skill), years, seniority, domains, flags.
    - [x] `006_screening.sql` creates `job_analysis` and `screening`; results are cached by prompt version.
    - [x] From T20/T20a: the prompt asks for one requirement per item (never several skills in one) and never the job title. Re-record Ollama `qwen3.5:4B` with thinking on and remove `RecordedRepliesTests`' known-issue marker if the merge is gone.
  - **Verify:** `core-test ScreeningTests` (fake provider plus recorded replies)
  - **Files:** `Sources/Screening/PostingCleaner.swift`, `Sources/Screening/AnalyzeJobTask.swift`, `Sources/Screening/AnalysisRepository.swift`, `Sources/Store/Schema/006_screening.sql`, `Tests/ScreeningTests/AnalyzeJobTaskTests.swift`
  - **Done 2026-10-19:** 12 offline tests plus recorded real replies.
    - **What's sent:** only the cleaned posting (title, company, location, description) and your skill and language names (a test pins the exact message).
    - **Checks:** a requirement can't be blank or the job title, and a matched skill must really be yours; the model's spelling is mapped back to yours.
    - **Storage:** `job_analysis` keeps one analysis per job with its model and prompt version; `AnalysisRepository` returns it only for the current prompt version, so a new prompt means a fresh analysis. `screening` is created for T29's verdict trail.
    - **Cleanup:** drops benefits, equal-opportunity and similar sections and lines (English and French); over the budget, requirements come first, then responsibilities, then the rest, with "About us" last.
    - **Live, on the sample posting:**
      - Gemini Flash-Lite: all 7 requirements, each its own item (Kubernetes, gRPC and French no longer merged), every skill match right, years and flags right, in 2.5 s.
      - Ollama `qwen3.5:4B`, thinking off (the default): all 4 must-haves right, but none of the 3 nice-to-haves, even with a prompt rule naming them. That passes SPEC's must-have bar; the nice-to-have gap is recorded as a known issue in `RecordedAnalysisTests`.
      - Ollama `qwen3.5:4B`, thinking on: all 7, each its own item, every match right, so **T20's merge is gone with this prompt**. It took 3,671 output tokens and 6 minutes, and at the default 1,500-token budget it spent everything thinking and sent an empty reply, which confirms thinking off as the default.
    - **T20's known-issue marker stays, reworded:** its fixture was recorded with the spike's one-line prompt, which still merges at temperature 0. The fix is shown by `analyzeJob-qwen3.5_4B-thinking-on.json`.
    - The full prompt evals (30 labelled postings) come with their own task (`PromptEvals`).

- [x] **T29 · Verdict and ranking** (S, test-first) · deps: T28
  - **Acceptance:**
    - [x] The verdict comes from must-have and nice-to-have coverage, the years and level policy, authorization flags and thresholds, and the rule id is stored.
    - [x] Ranking: verdict, then Canada before US, then match (success criterion S7).
  - **Verify:** `core-test ScreeningTests`
  - **Files:** `Sources/Screening/Verdict.swift`, `Sources/Screening/Ranking.swift`, `Tests/ScreeningTests/VerdictRankingTests.swift`
  - **Done 2026-10-19:** test-first, 8 tests (`VerdictTests`, `RankingTests.rankingCanadaFirst` for S7, `ScreeningTrailTests`).
    - **Rules, in order:** your profile against the posting's flags (won't sponsor, remote only in a country where you'd need a visa, clearance, French required), then your levels, then years, then coverage.
    - **Storage:** `ScreeningRepository` stores each decision in `screening` with its stage, rule id, coverage and reasons, prefilter rejections included. Ranking sits in `Verdict.swift` rather than its own file, as it's one small function.
  - **Decided here (tell me if any should change):**
    - **Coverage** counts skill requirements only. Conditions (work authorization, clearance, languages, degrees, travel, licences) are judged by the flags and your profile, so "Must be entitled to work in Canada" never counts against your skills. A posting listing no skills at all is a maybe.
    - **Thresholds** are in your "screening" preferences: yes at 75% of must-haves covered, maybe at 50%, no below.
    - **Years:** more than your limit is a no. Up to 2 years more than your master resume's total is a maybe at most; more than that is a no. Without your total years, only the limit applies.
    - **Match** (for ranking) weighs must-haves 80% and nice-to-haves 20%.
    - **Rank** = verdict, then your country order (Canada first by default, a country you didn't list last), then match.
    - **TN note:** a US job that won't sponsor shows "Possible TN route" for a Canadian citizen (SPEC §5.9). It never changes the verdict.

- [x] **T30 · Screening pipeline** (M) · deps: T29, T14
  - **Acceptance:**
    - [x] Fetch → normalize → de-duplicate → prefilter → analyze (rate-limited, cancellable) → verdict → rank, with progress events.
    - [x] Run stats record the prefilter drop rate and the counts of new `yes` and `maybe` jobs.
    - [x] Integration test with a fake source and a fake LLM.
  - **Verify:** `core-test PipelineTests`
  - **Files:** `Sources/Pipeline/ScreeningRun.swift`, `Sources/Pipeline/PipelineEvents.swift`, `Tests/PipelineTests/ScreeningRunTests.swift`
  - **Done 2026-10-20:** 8 tests: an end-to-end fetch and screen with a fake board and a fake AI that answers per job title, a reused stored analysis, no AI set up, the daily budget, a failed analysis, which errors stop analysis, cancelling, and `JobRepository.setVerdict`.
    - **Run order:** `ScreeningRun` takes every new job without a verdict (new ones and any left from earlier runs), prefilters them all first, then analyses the survivors two at a time, reusing a stored analysis while the prompt version is the same. It records each decision and sets verdict and rank. `PipelineRun` chains fetch and screening into one event stream, and "Fetch now" in the app runs it; the window subtitle shows "Screening 12 of 40 · 5 yes · 3 maybe", then the yes and maybe counts.
    - **Your overrule wins:** `setVerdict` changes only verdict, source and rank, and never touches a job whose verdict you set yourself.
    - **When analysis stops:** without an AI key, with the daily budget or the provider's quota used up, or with a rejected key, analysis stops and the remaining jobs wait for the next run without a verdict ("12 waiting for AI"). Any other error fails just that job, which also waits.
    - **Run stats** (`run` kind "screen"): screened, prefiltered and drop rate (S6), analysed, failed, waiting, and the new yes, maybe and no counts.
    - **Notifications** (step 8) aren't here yet; they come with the menu bar work.
  - **Heads-up for your first run:** the prefilter filters nothing until you set Settings › Search (T31), so set it first. Otherwise every job already fetched goes to analysis, one AI call each (Flash-Lite by default, within your 300-a-day budget). "Screen again" re-screens later without new AI calls for jobs already analysed.

- [x] **T31 · Today screen and verdict explanations** (M) · deps: T30, T17
  - **Acceptance:**
    - [x] Today shows the ranked list with verdict and country chips and filters; Run and Stop show progress.
    - [x] The job explanation shows requirements covered and missing, flags, and the deciding rule, and lets you overrule the verdict.
    - [x] Settings has search preferences (titles, locations, countries in order) and work authorization (marked "stays on this Mac").
  - **Verify:** `app-build`; manual run on your watchlist
  - **Files:** `App/Kairos/Screens/TodayView.swift`, `App/Kairos/Screens/JobExplanationView.swift`, `App/Kairos/Settings/SearchPreferencesView.swift`, `App/Kairos/Settings/WorkAuthorizationView.swift`
  - **Done 2026-10-20:** app builds clean; checked in light and dark with `--render-snapshots` (Today, the explanation, Search settings).
    - **Today:** opens first. The list holds screened jobs you haven't acted on, ranked, grouped by your country order. The All, Yes, Maybe and No filter has counts. Each row shows a verdict pill (colour, icon and word), the deciding reason under the company for a maybe or a no (a partial match now names the gap: "Missing Java"), location, work, source and match score. "No" rows are dimmed with `ink-dimmed`. The sidebar badge counts yes and maybe.
    - **Run:** "Run now" runs the whole pipeline; the progress bar covers fetching then screening, with Stop. The subtitle reads "Last run 8:02 AM · 312 fetched · 61% filtered before AI · 4 waiting for AI".
    - **Explanation:** score and verdict, the deciding reason and who decided (the prefilter, the AI's reading, or you), must-haves and nice-to-haves each covered (with the matched skill), missing, or a condition checked against your profile, notes such as "French is an asset" or "Possible TN route", "Change verdict", "Open posting", "Not for me" (skips it and keeps the verdict), and the posting text in a disclosure.
    - **Core, test-first** (3 tests): overruling (`setUserVerdict`, recorded in the trail as stage "user"), `setState`, `clearScreening` (keeps your verdicts and jobs you've acted on), and `latestByJob`.
    - **Settings › Search:**
      - job titles, words to skip, levels, countries in order with provinces or states for on-site work, remote on or off;
      - a years limit and a posting-age limit, blocked companies, and the yes and maybe thresholds;
      - work authorization per country and clearance, marked "Stays on this Mac";
      - "Screen again" re-screens the jobs you have with the new settings, reusing stored analyses.
  - **Visual differences from `Main.dc.html`:**
    - The verdict filter's segments show words and counts, not icons; a segmented control draws one or the other.
    - The run status is the window subtitle, as in Jobs (T14).
    - "Work" shows on-site, hybrid or remote without the days a week, which postings don't state in a form Kairos parses.
    - The US section has no "remote roles that hire in Canada first" subtitle.
    - The inspector shows no salary range yet.
    - Its summary is the coverage line ("Covers 4 of 4 must-haves…") rather than the mockup's prose.
    - Conditions read "A condition, checked against your profile" rather than "Covered · From your profile", since a French asset you don't have isn't covered.
    - No "You list it as Can discuss" on missing rows.
    - "Build resume" is disabled until Slice 4.
  - **Visual differences from `Sources.dc.html`'s "Search for" panel:** it lives in Settings › Search, not beside Sources. Job titles aren't numbered or draggable (their order doesn't affect ranking). Countries move with an arrow rather than by dragging.
  - **Not drawn in the design and decided here:** levels, limits, blocked companies, thresholds and work authorization in Search settings; the "Change verdict" menu; Today's empty state.

#### Checkpoint D
- [ ] Real run on your watchlist; you review the verdicts; prefilter drop rate recorded (success criterion S6 baseline)

### Slice 4: Tailoring and rendering

- [x] **T32 · Render pipeline and classic template** (M) · deps: T06, T15
  - **Acceptance:**
    - [x] `TypstRunner` is hardened: timeout, error capture, `--ignore-system-fonts`, bundled fonts.
    - [x] `classic.typ` reads resume JSON; the header comes from the contact block; section order and visibility are inputs.
    - [x] A golden test checks the PDF text and page count for a fixture resume.
  - **Verify:** `core-test RenderTests`
  - **Files:** `Sources/Render/TypstRunner.swift`, `Sources/Render/ResumeDocument.swift`, `Sources/Render/Templates/classic.typ`, `Sources/Render/Fonts/` (open-licensed), `Tests/RenderTests/ClassicTemplateTests.swift`
  - **Done 2026-10-20:** 5 new tests, plus the 3 from T06.
    - **Golden test:** the sample resume renders on one page, and its lines appear in reading order (`Fixtures/render/classic-golden.txt`). It checks order rather than exact text because CI's PDFKit differs from this Mac's.
    - **Other tests:** section order and visibility come from the input; Typst markup in content (`#import`, `*`, `$`, `@`, `<…>`) prints literally; the same input gives the same bytes; the PDF uses the bundled serif; the fonts ship with the module.
    - **`ResumeDocument`** is what templates read: header (name, optional headline, contact items with optional links), sections in order with `visible`, items (title, subtitle, location, dates, bullets), skill groups and style (paper, size, margin). `ResumeRenderer` renders one and counts pages with PDFKit, for T35's page fitting.
    - **Runner hardening:** bundled fonts via `--font-path`, one-line errors (`--diagnostic-format short`, warnings dropped, at most 2,000 characters), a sealed environment (only HOME and TMPDIR, both the throwaway folder, so a shell's TYPST_* variables can't change the output), and `--creation-timestamp` for reproducible PDFs.
    - **Fonts:** Source Serif 4 Regular, Italic, Semibold and Bold (SIL OFL 1.1, 0.9 MB) in `Sources/Render/Fonts/`, with their source and SHA-256 in its README. The debug app is now 55 MB, within the 80 MB budget.
    - **Converting your master resume** (or a tailored build) into a `ResumeDocument` lives in Tailoring (T33 onwards), since SPEC §4 lets Render know only Tailoring's types.
  - **Visual differences from the resume in `Build.dc.html`:** an optional headline under the name (the mockup has none; it's omitted when empty); the contact line follows the order given (the mockup starts with the city); skills can be labelled groups as well as the mockup's single line; the mockup shows Toronto Metropolitan University sample data where the fixture uses Waterloo.

- [x] **T33 · Entry selection and strict verifier** (M, test-first) · deps: T29, T15
  - **Acceptance:**
    - [x] The selector scores bullets and projects by requirement overlap (keywords, `Synonyms.json`, recency).
    - [x] The strict verifier enforces `source_ids` existence, technologies and numbers from the cited bullets, years, and every hard limit (SPEC §5.3).
    - [x] The 30-job fixture suite scaffold exists; violations are reported with the bullet and rule.
  - **Verify:** `core-test VerifierSuite`
  - **Files:** `Sources/Tailoring/Selector.swift`, `Sources/Tailoring/Verifier.swift`, `Sources/Tailoring/Synonyms.json`, `Tests/TailoringTests/VerifierSuite.swift`, `Tests/Fixtures/tailoring/`
  - **Done 2026-10-20:** test-first: 5 selector tests, 11 verifier tests, and `VerifierSuite` over 3 fixture jobs (16 bullets, each breaking exactly the rules it expects). New module `Tailoring` (store, llm, master-resume, per SPEC §4). Job requirements come in as plain text (`JobRequirements`); the pipeline converts screening's analysis, since tailoring doesn't depend on screening.
    - **`Synonyms.json`** has 97 technologies with their other spellings ("Postgres", "k8s", "golang"), plus concepts for selection only ("message queues" means Kafka, RabbitMQ…). Names that are also ordinary words count only as written ("Go", "React", "REST"), so "go live" isn't a claim of Go. C and R aren't listed: one letter is too ambiguous.
    - **Selector:** a requirement counts once per bullet: fully (must 2, nice 1) for a shared technology, half for a shared keyword; numbers add 0.25. Roles run most recent first, keeping 5, 4, 3, then 2 bullets, and never fewer than one. Projects are ranked by relevance and recency (two at most, or the most recent if none is relevant). Skills are Proven only, the ones the posting names first.
    - **Verifier, strict:** every bullet cites existing master-resume bullets and names only technologies in them or in your Proven skills (a Can-discuss skill or a certification's subject isn't enough), and only numbers from them ("4.2 million" matches "4.2M"; digits in names like p99 and dates like 2022 don't count).
    - **Verifier, every mode:** years claimed up to your total; employer, title and dates exactly as in an experience; degrees and certifications that exist; nothing naming the hiring company or its products unless your master resume does; no date of birth, SIN or SSN, marital status or attached photo. Stretch mode's gap bullets need no source, may use Can-discuss skills and estimate numbers (T37 completes them).
    - **Fixtures:** the suite and its JSON format are in `Tests/Fixtures/tailoring/README.md`; T34 and T39 add writer output until it reaches 30 jobs (S9).

- [x] **T34 · Section writers and polish** (M) · deps: T33, T23
  - **Acceptance:**
    - [x] Writer tasks for summary, skills, experience and projects (prompt v1, schemas with `source_ids`). They receive only the selected entries.
    - [x] Polish swaps AI-sounding phrases, de-duplicates opening verbs, enforces length, and applies en-CA or en-US spelling by job country.
  - **Verify:** `core-test TailoringTests`
  - **Files:** `Sources/Tailoring/WriteSectionTasks.swift`, `Sources/Tailoring/Polish.swift`, `Sources/Tailoring/Spelling/en-CA.json`, `Sources/Tailoring/Spelling/en-US.json`, `Tests/TailoringTests/PolishTests.swift`
  - **Done 2026-10-20:** 13 writer tests and 5 polish tests, plus recorded live replies (`RecordedWriterTests`).
    - **What's sent:** writers get only the selected entries, your Proven skill names, the job title and requirements, and a spelling line for the job's country. Prompts name entries "e1" and bullets "b1", never UUIDs, and code maps them back.
    - **Checks:** each reply's check covers every entry written, no unknown ids, no citing another entry's bullet, at most 260 characters, and every bullet through the strict verifier. A bad reply gets one repair call quoting exactly what was wrong (for example "“Rust” isn't in the cited bullets or your Proven skills"). The summary must stay within your total years and your skills; the skills writer may only group your Proven skills, each once, in your spelling.
    - **Polish:** swaps AI-sounding phrases ("spearheaded" to "led", "leveraging" to "using", "in order to" to "to"), varies repeated opening verbs, cuts over-long bullets at a clause, ends bullets cleanly, and spells for the job's country. The spelling lists are 45 word pairs in `Spelling/`; Canada keeps -ize but uses -our, -re and a doubled l. Running it twice changes nothing more.
    - **Live on Flash-Lite** (the sample resume and the T28 posting): all four writers produced grounded output on the first call, in about 1 s each, and the replies are kept in `Tests/Fixtures/writers/`. The experience bullets kept every number exactly; the summary used your 5 years; the skills writer grouped 8 Proven skills. Weak spots for a later prompt version: the project bullet was awkward ("…gathering 400+ stars using Go and Docker") and the summary had some filler.
    - **Prompts:** v1 of `writeExperience`, `writeProjects`, `writeSummary` and `writeSkills`, in `LLM/Prompts/`. The full prompt evals come with T39.

- [x] **T35 · Match score, rewrite loop, build queue** (M) · deps: T34, T32
  - **Acceptance:**
    - [x] Match score uses the SPEC §5.3 weights. Sections under 70 get `rewriteSection`, at most 3 passes, keeping the best version. Page fitting drops the lowest-ranked bullets.
    - [x] `007_builds.sql` creates `build` and `artifact`; builds record `master_version` and mode.
    - [x] The build queue (2 workers) resumes a crashed build from cached steps.
  - **Verify:** `core-test TailoringTests`, `core-test PipelineTests`
  - **Files:** `Sources/Tailoring/MatchScore.swift`, `Sources/Tailoring/BuildLoop.swift`, `Sources/Pipeline/BuildQueue.swift`, `Sources/Store/Schema/007_builds.sql`, `Tests/TailoringTests/BuildLoopTests.swift`
  - **Done 2026-10-20:** 18 new tests: match score 8, build loop 7, build repository 2 and the tailored header 1 in TailoringTests; 3 queue tests in PipelineTests; the document conversion in RenderTests.
    - **Match score:** SPEC's weights (must-haves 40, nice-to-haves 10, evidence in bullets rather than only the skills list 15, domain 10, metrics 10 with full marks at 60% of bullets carrying a number, language 10, structure 5). Conditions such as work authorization aren't scored. Employers count as domain evidence. Each section gets a score out of 100 and findings: requirements no bullet shows, bullets without numbers, weak openers ("responsible for"), first person, buzzwords, repeated verbs and long bullets.
    - **Build loop:** select, then the four writers in parallel, polish and score. Experience or projects under 70 get `rewriteSection` (prompt v1) with the findings, at most 3 passes; a rewrite is kept only if it scores higher, and a pass with no gain stops. A writer that still fails after its repair falls back to your bullets word for word. Lite mode copies your bullets and writes only the summary and skills (T38 adds the cover letter).
    - **Page fitting:** renders and counts pages, then drops the lowest-ranked bullet (each bullet carries its sources' selector score), every entry keeping one, then whole projects, until it fits.
    - **Contact line:** built by code from your contact block (phone shown as "(416) 555-0123"); a GitHub or portfolio link that doesn't validate is left off.
    - **Storage:** `007_builds.sql` creates `build` (mode, master version, status, content, score and breakdown, rewrite count, error) and `artifact` (sha256, local path); `BuildRepository` reads and writes them.
    - **`BuildQueue`:** two workers. It refuses a job without an analysis, a master resume that isn't ready (S14) and a missing AI setup, each with a message in words. It renders and saves the PDF, records its sha256, and streams step events. `resumeInterrupted()` restarts builds left queued or running, and the writers' replies come from the result cache, so finished steps cost nothing (tested).
    - **Live:** a whole build on Gemini Flash-Lite with the real typst took 3.5 s: score 87, one rewrite (projects, which then scored 75), one page, nothing fell back. Weak spots for later prompt versions: the summary repeats a bullet word for word, and the skills writer grouped oddly (Go and Java under "Backend", Python alone under "Languages").
    - **Dependencies:** Render now depends on Tailoring (types only, as SPEC §4 maps it) to lay out a build.

- [x] **T36 · Build screen** (M) · deps: T35, T31
  - **Acceptance:**
    - [x] Build is blocked until the master resume is ready (success criterion S14). Mode picker: strict or lite (stretch appears only when it's on).
    - [x] Progress, PDF preview (PDFKit), and a bullet trace linking each bullet to its master-resume entries.
    - [x] "Built from version N" note; Reveal in Finder; export.
  - **Verify:** `app-build`; manual strict build on a real job
  - **Files:** `App/Kairos/Screens/BuildView.swift`, `App/Kairos/Screens/PDFPreview.swift`, `App/Kairos/Screens/BulletTraceView.swift`
  - **Done 2026-10-20:** app builds; the core changes have tests (`BuildRepository.recent`, `BuildQueue.setRouter`). The manual strict build on a real job is yours: open a Yes job in Today and choose Build resume.
    - **Starting a build:** a job's explanation in Today has a primary "Build resume" button. It's disabled, with the reason as its tooltip, until your master resume is ready (S14) and the job has an analysis; `startBuild` checks readiness again before queueing. A started build opens the Builds section.
    - **Builds section:** the toolbar has the Builds menu (every recent build, newest first), the mode picker (Full, Lite), the primary "Build again", Save PDF (a save panel), Reveal in Finder and Mark applied (the job leaves Today). Stretch joins the picker once T37's setting is on.
    - **Left column:** the six build steps (done, running, waiting or failed), live from the queue's events; the match score with SPEC's components out of their weights; "Missing from your bullets"; and "Built from master resume version N", which warns when you've changed your resume since.
    - **Middle:** the PDF in PDFKit, scaled to fit. Selecting text in it selects the matching line in the trace.
    - **Right column:** every line of the build, and the chosen one traced to the master-resume bullets it cites ("Acme · Engineer · bullet 2 of 4", the text, its metric and skill chips). Its checks are the strict verifier run again against your resume as it is now, so an edit since the build shows up. "Be ready to discuss" says it's empty while Stretch is off.
    - **PDFs** are saved in `Builds/` beside the database; the queue renders with the bundled typst and restarts unfinished builds at launch.
    - **Visual differences from `Build.dc.html`:**
      - The score breakdown shows SPEC §5.3's components (must-haves, nice-to-haves, evidence, domain, metrics, language, structure); the mockup's Seniority and Location rows aren't in SPEC's score.
      - The list of lines sits above the trace in the right column; the mockup only shows the trace, with lines chosen by clicking the PDF. Clicking a line in a PDF isn't reliable in PDFKit, so selecting text works too.
      - No "What changed" text per line. The build doesn't store a diff, and the trace shows the source bullets beside the line instead.
      - Choosing another build is a toolbar menu, not the mockup's header tabs, to keep one toolbar.
      - The PDF pane can't be checked in `--render-snapshots`, because PDFView draws asynchronously; the PDF itself was checked by page count.
    - **Undrawn cases, decided here:** no builds yet (an empty state pointing to Today); a running build (a spinner where the PDF goes); a failed build (the step it stopped at in error colour with the message, and the message where the PDF goes; after a relaunch only the latter, since steps aren't stored); a source bullet since deleted (a sentence saying so); dark mode reuses the tokens.

- [x] **T37 · Stretch mode** (M) · deps: T36
  - **Acceptance:**
    - [x] Settings toggle, off by default, with an explanation of what changes.
    - [x] The `gapBullets` task is limited to Can-discuss skills and a per-role count of 0–2. Stretch verifier rules apply, and hard limits still hold.
    - [x] Gap bullets are stored `verified: false`, highlighted in the trace, and listed under "Be ready to discuss"; nothing marks them in the PDF.
  - **Verify:** `core-test VerifierSuite` (stretch cases: 0 hard-limit violations, 100% flagged)
  - **Files:** `Sources/Tailoring/GapBulletsTask.swift`, `Sources/Tailoring/Verifier.swift`, `App/Kairos/Settings/StretchModeView.swift`, `App/Kairos/Screens/ReadyToDiscussView.swift`
  - **Done 2026-10-20:** 15 new tests: stretch mode 6 (one runs 9 problem cases) and stretch verifier 2 in TailoringTests, 4 stretch build-loop tests, the stretch half of `VerifierSuite` with a new 13-case fixture job, a queue test and a render test; plus an opt-in live test.
    - **Setting:** `StretchSettings` (synced key `stretch_mode`): off, up to 1 extra line per role. Settings, General shows the switch, "Up to 1 / Up to 2", and what changes: off means every line comes from your master resume; on adds lines for uncovered requirements using only Can-discuss skills, with estimated numbers allowed; each one goes on "Be ready to discuss"; and what never changes in any mode. With the switch on and no Can-discuss skills, it says builds won't stretch.
    - **`gapBullets` (prompt v1):** it gets only the requirements no bullet shows that one of your Can-discuss skills answers (conditions such as work authorization never count). It also gets the role headings with their written bullets, your skill names, your total years and the cap; never contact details or UUIDs (roles "e1", requirements "r1"). Its check: roles and requirements given, at most the cap per role, each requirement once, 260 characters, naming a Can-discuss skill that answers the requirement, and the stretch verifier. One repair call; if it still fails, the build goes on without gap bullets. An empty reply is fine.
    - **Hard limits in a gap bullet's words:** a gap bullet cites nothing, so the verifier now rejects one claiming a degree, certification or licence (unless it names one of yours exactly as written) or a title or promotion ("Promoted…", "as tech lead"). Years, the hiring company and personal fields were already checked. Bullets your master resume backs keep the strict rules unchanged.
    - **Build loop:** gap bullets come after the rewrites, so they only cover what rewriting couldn't, and before page fitting. They go after the role's own bullets, polished with them, and rank lowest, so a full page drops them first.
    - **Flagging:** stored bullets now carry `verified` (false for a gap bullet) and `covers` (the requirement it answers). The PDF lays them out like any other line (tested).
    - **Queue and app:** a stretch build doesn't run while the setting is off (it fails with a message in words). With the setting on, Build resume in Today starts a Stretch build, and the Build screen's picker shows Full, Stretch and Lite. Stretch builds show an "Added gap bullets" step. In the trace, gap lines have the Can-discuss dashed outline and the word "Stretch". Their trace explains that they aren't from your master resume, shows the Can-discuss skill chips, and lists five checks for the hard limits. "Be ready to discuss" lists each one with "Covers: …", and choosing one selects it.
    - **Live on Flash-Lite** (`scripts/live-llm.sh gapBulletsOnGemini`, sample resume, cap 2): one call, 1.2 s. Both bullets passed on the first try: Terraform and Rust, each with an estimated percentage. Recorded in `Tests/Fixtures/writers/` for the offline check.
    - **Visual differences from `Build.dc.html`:**
      - The mockup shows "Be ready to discuss" only empty (Stretch off). The filled list is undrawn: each line is a row with the Can-discuss dashed outline, its requirement and its skill chips, reusing the design's chip rule.
      - The section's Stretch switch is there as drawn and changes the same setting as Settings. Its empty text names your first Can-discuss skill where the mockup says "Terraform".
      - The switch's track draws grey in snapshots because offscreen windows are inactive; it's tinted in the app.
    - **Undrawn cases, decided here:** Settings, General (only Stretch mode for now) reuses the form section pattern of Settings, Search; gap lines in the trace use the dashed outline plus the word "Stretch", so the dashes are never the only signal; a finished build whose PDF is missing now says so instead of showing a spinner.
    - **Your step:** turn Stretch on, mark a skill or two Can discuss, and build a job that asks for them. Check the lines read as something you could defend.

- [x] **T38 · Lite mode and cover letter** (M) · deps: T36
  - **Acceptance:**
    - [x] Lite mode copies the selected bullets word for word; only the summary and skills are written.
    - [x] The `coverLetter` task returns paragraphs as JSON; the verifier checks its claims; code adds the greeting, name and contact line; `cover.typ` renders it.
  - **Verify:** `core-test TailoringTests`; manual lite build and cover letter
  - **Files:** `Sources/Tailoring/LiteBuild.swift`, `Sources/Tailoring/CoverLetterTask.swift`, `Sources/Render/Templates/cover.typ`, `Tests/TailoringTests/CoverLetterTests.swift`
  - **Done 2026-10-20:** 13 new tests: cover letter 4 (one runs 13 problem cases) and lite and letters in a build 5 in TailoringTests, the letter document 1 and the cover template 2 in RenderTests, and a queue test; plus an opt-in live test. The manual lite build and letter on a real job are yours.
    - **Lite, now truly word for word:** T35 built lite mode in `BuildLoop` (so there's no separate `LiteBuild.swift`), but polish still ran over the copied bullets and could change words ("Spearheaded" to "Led", "color" to "colour") and add a full stop. Copied bullets, in lite mode or when a writer falls back, now skip polish (tested with such a bullet). Adding Stretch gap bullets no longer re-polishes a role's own bullets either.
    - **`coverLetter` (prompt v1):** it gets the job's title, company and requirements, the build's selected entries with their bullets and metrics, your Proven skill names and your total years. It never gets your name or contact details. It returns 3 to 5 paragraphs. Its check: 150 to 450 words; no greeting, sign-off, email, phone, link or "[placeholder]", since code adds those; and every paragraph through the verifier's new letter rules. One repair call; if it still fails, the build finishes without a letter.
    - **Verifier, letters:** the summary's rules (technologies from your Proven skills or bullets, numbers from your master resume, years up to yours, no personal fields). The letter may name the company it's written to, but never its products, and may not claim a degree, certification or licence you don't list.
    - **Code adds:** your name and contact line (as on the resume), the date in the job country's long form, "Hiring team" and the company, "Re: <job title>", "Dear <company> hiring team,", and "Sincerely," with your name. Polish (phrasing and spelling) runs over the paragraphs.
    - **`cover.typ`:** US Letter, 1 inch margins, 11 pt Source Serif 4, the resume's header. Like `classic.typ` it reads everything from JSON, so markup prints literally (tested).
    - **Storage:** the build table already had `cover_letter` JSON, so no migration: queueing a build with a letter stores `{"status":"requested"}`, so a restarted build still writes it. Finishing replaces that with the letter, or with why there isn't one. The letter's PDF is saved beside the resume as `<id>-cover-letter.pdf` with an artifact of kind `cover_letter`. A letter that fails never fails the build: its step shows why.
    - **App:** a "Cover letter" checkbox beside Build resume in Today and a toggle in the Build screen's toolbar share one per-Mac preference (`@AppStorage`, a convenience rather than a synced setting). A build with a letter shows a "Wrote cover letter" step and a Resume / Cover letter switch above the PDF; Save PDF and Reveal in Finder act on the one shown.
    - **Live on Flash-Lite** (`scripts/live-llm.sh coverLetterOnGemini`): repaired once, 2 calls, 2.7 s. Grounded: every number and technology is in the sample resume. Weak spot for a later prompt version: the tone is stock ("I am writing to express my interest…", "secondary technologies highlighted in your posting").
    - **Visual differences:** no mockup draws a cover letter. Undrawn, decided here: the Resume / Cover letter switch is a segmented picker above the PDF, the toolbar toggle and Today's checkbox use system controls, and the letter's step reuses the step rows. In a narrow inspector, Today's actions now wrap to two rows (build and its checkbox, then Open posting and Not for me) instead of truncating. The right column keeps tracing resume lines while the letter is shown.

- [x] **T39 · Prompt privacy tests and eval harness** (M) · deps: T38
  - **Acceptance:**
    - [x] `PromptPrivacyTests` renders every task's prompt for a fixture user and fails if any contact value or private setting appears.
    - [x] `PromptEvals` (opt-in live) has 30 labelled postings and reports must-have precision and recall and the first-write verifier pass rate to `evals/<date>-<model>.json`.
    - [x] The first baseline report is committed and meets the `CONSTRAINTS.md` thresholds, or the gap is raised with you.
  - **Verify:** `core-test PromptPrivacyTests`; `KAIROS_LIVE_LLM=1 core-test PromptEvals`
  - **Files:** `Tests/LLMTests/PromptPrivacyTests.swift`, `Tests/LLMTests/PromptEvals.swift`, `Tests/Fixtures/evals/`, `evals/README.md`
  - **Done 2026-10-20:** 7 new tests (privacy 4, eval fixtures 2, the recorded eval 1) plus the opt-in live eval. LLMTests now also depend on Store, MasterResume, Screening and Tailoring, so one target reaches every task.
    - **Privacy test:** a fixture user, Avery Quill, has every contact field filled in. Their contact details also appear where people write them anyway: a bullet linking their GitHub, a business named after them, and a resume whose top line reads "Canadian citizen · Secret clearance · Will need sponsorship". Avery's private settings say citizen in Canada, needs sponsorship in the US, and has clearance.
      - **What it checks:** the import tasks and `analyzeJob` are rendered directly. Every build task is checked as a whole Stretch build with a letter sends it, through the fake provider, with unusable replies so each writer also falls back and the rewrite pass runs.
      - **Pass conditions:** no message of any task may contain a contact value in any common format; no data message may contain a private setting; every task with a prompt must be checked (`triage` and `select` have none yet).
    - **Two gaps it found, now fixed:**
      - **Contact details inside bullets:** contact details typed into a bullet or an employer name went to the writers as-is. Every build-loop call now goes through `Redacted`, which removes your contact details from the data it sends (instructions untouched). The writers' checks reject a reply that copies the `[removed]` marker. I checked that the test fails without the wrapper.
      - **Work status in imported resumes:** a resume's own "Canadian citizen", "permanent resident", "requires sponsorship", "eligible to work in the US" or "Secret clearance" was sent to `importResume`. `ContactRedactor.redactWorkStatus` now removes those status phrases (only those: "built a visa appointment tracker" stays) before the import and the GitHub README are sent.
    - **Eval harness:**
      - **Postings:** 30 fictional postings across backend, frontend, data, DevOps, mobile, ML, QA, security, .NET, embedded, games, support and management, in Canada and the US. 123 must-haves and 56 nice-to-haves are hand-labelled, conditions included.
      - **Run:** for each posting it runs `analyzeJob`, then `writeExperience` for a fictional generalist (Robin Ashford). It takes the writer's first reply (no repair) and runs the strict verifier on every bullet.
      - **Scoring:** a prediction matches a label by a shared technology or most of the words either way.
      - **Report:** `evals/<date>-<model>.json` has the totals, the thresholds, and each posting's wrong must-haves, missed labels and verifier findings. The test fails below 0.85 precision, 0.80 recall or 95% first-write passes.
      - **Models:** Flash-Lite by default for both tasks (`KAIROS_EVAL_MODEL`, `KAIROS_EVAL_WRITER_MODEL`), so Flash's 20-a-day free allowance isn't spent. `evals/README.md` explains running and reading it.
      - **Recorded replies:** every run saves its 60 replies under `Tests/Fixtures/evals/replies/<model>/`. `RecordedEvalTests` scores them again offline on every test run, with the selection date fixed so they stay valid: the recorded run must still meet the thresholds and every bullet must still pass.
    - **Baseline** (`evals/2026-10-20-gemini-flash-lite-latest.json`, Flash-Lite for both tasks, ~15 minutes, paced by the free tier's per-minute limit): must-have precision 100%, recall 100%, first-write pass rate 100% over 141 bullets. An earlier run the same day scored 99.2% recall (it dropped "Mentoring engineers"), so expect a point of noise. Raised with you:
      - **The postings are tidy.** Each has a "Requirements" heading, and the model copies those lines nearly word for word. Real postings bury requirements in prose; Checkpoint D's real run is the better test of extraction.
      - **Flash-Lite barely tailors.** I read all 141 bullets against their sources: none claims anything its source doesn't (S9 strict holds), but 129 are the source word for word. On Flash-Lite, Full mode is close to Lite, and the pass rate is high partly because copying can't fail. The writers' default is Flash, which this baseline didn't use.

### Checkpoint E: R1 exit
- [x] Stories 4, 5 and 8 pass; success criteria S8, S9, S14 and S15 (privacy half) pass (checked 2026-10-20, evidence below)
  - **Story 4, explained verdicts:** Today's explanation shows each requirement covered or missing with the skill that matched, the authorization, clearance and French flags, the deciding rule or score and who decided, and an overrule menu (T29–T31; ScreeningTests, snapshots).
  - **Story 5, one-click resume:** Build resume gives a PDF within the page budget, plus an optional cover letter (T35–T38). A live Flash-Lite build took 3.5 s; a live letter 2.7 s.
  - **Story 8, one master resume:** import from your resume, GitHub projects, required contact fields, editing any time; every build and letter draws only from it (T16–T24; Checkpoint C with your real resume).
  - **S8:**
    - Typst renders a resume or a letter in 9–11 ms (target 1 s).
    - Page fitting keeps the page budget (BuildLoopTests).
    - The build median over real use comes from your week: each build's subtitle now shows how long it took. Model latency is 1–3 s a call; the free tier's per-minute limit is what stretches a build, to roughly 30 s for about 8 calls.
  - **S9:**
    - Strict: 0 unsupported claims across 30 jobs: `RecordedEvalTests` (141 real bullets, all read against their sources) plus `VerifierSuite`'s hand-written cases.
    - Stretch: `VerifierSuite`'s stretch job lets no hard limit through and flags every gap bullet.
  - **S14:** Build stays blocked until your resume is ready, with the missing fields now written under the button, not only in its tooltip (MasterResumeTests, `BuildQueueTests.aBuildNeedsAnAnalysisAndAReadyResume`, snapshot `job-blocked`). The SPEC's "UI test" is a snapshot, since the project has no UI test target.
  - **S15, privacy half:** `PromptPrivacyTests`. The calls half (≥ 98% valid over a week) comes from your week's `llm_call` outcomes.
- [x] You review a week of sample builds; Phase 2 tasks refined together (2026-10-21, your decision: your two days of real runs and the polish work they drove, P1–P6, count as the review; Phase 2's order is below)
  - **Worth knowing first:** on the free tier, Flash allows only 20 calls a day and a Full build uses 6–12, so the writers' default (Flash) allows two or three builds a day. Pick Flash-Lite for the writers in Settings, AI providers, or add more keys, for the review week. Builds on Flash-Lite will mostly copy your bullets (see T39's baseline).

---

## Polish (branch `polish`, from your first real runs, 2026-10-20)

Asked for by you after Checkpoint E's first item. Root cause of the false rejections, from your 31 analysed postings and a live experiment:
- **It was the screener's design, not the model.** It saw only skill names, matched each requirement to one name exactly ("never stretch"), counted soft skills and unrecognized conditions as missing, and guessed conditions from keywords ("residing in Nova Scotia" and "BS/MS in Computer Science" weren't on the list; "(or equivalent) language" made SQL and Python a condition).
- **Flash didn't fix it.** Today's prompt on Flash did no better than Flash-Lite (fewer must-haves covered on 4 of 6 postings).
- **The redesign did.** Categories, matching against the whole resume with cited evidence, and partial credit turned 5 rejections into Yes and 6 into Maybe on Flash-Lite. Non-engineering roles stayed No.
- **One resume gap.** Nothing in the master resume shows AI coding tools, so "proficiency in AI tools" can only be partial.

Your decisions:
- the screener may send skills, education, and experience and project bullets (never contact details, authorization or home location);
- work authorization, location, availability and willingness-to-learn requirements count as met;
- thresholds stay 75% and 50%, with partial matches worth half and soft skills ignored;
- screens become Fetch · Review · Builds, with a full-screen Job page.

- [x] **P1 · Screener v2** (M)
  - **Acceptance:**
    - [x] `analyzeJob` prompt v2: each requirement has a kind, a category (skill, experience, education, location, authorization, language, availability, soft) and a match (yes, partial, no, not judged) citing evidence ids from a screening profile. The profile holds skills, education, experience, projects and languages, with contact details redacted.
    - [x] The check rejects unknown evidence ids, and a yes or partial without evidence.
    - [x] Coverage counts must-have skills, experience, education and languages: yes 1, partial ½. Soft, location, authorization and availability items are shown but never counted.
    - [x] The eval baseline is rerun on prompt v2 and recorded; PromptPrivacyTests covers the new input.
  - **Verify:** `core-test ScreeningTests`, `core-test LLMTests`; live rerun of the eval and of your analysed postings
  - **Done 2026-10-20:**
    - **Screening profile:** your master resume as numbered evidence (`s` skills, `c` Can-discuss, `d` degrees, `l` languages, `x` roles and `p` projects with `b` bullets, `y1` total years). Contact details are redacted from every line; there's no school, no location and no authorization. A Can-discuss skill alone is a partial at most.
    - **Prompt v2:** categories, matches, evidence. Alternatives stay one item and one alternative is enough. A years requirement cites `y1`; before that id existed, 8 of 9 repairs were years judged partial with nothing to cite. Prompt v1 stays in the bundle for analyses stored before.
    - **Scoring:** partial counts ½; only counted must-haves appear in "Missing …". Stored v1 analyses score exactly as before, and stored whole-number coverage still decodes.
    - **Results, Flash-Lite:**
      - The eval baseline meets every threshold: precision 100%, recall 100%, first-write pass rate 100% over 145 bullets, and no analysis needed a repair.
      - On your 31 analysed postings: 6 Yes, 9 Maybe and 16 No, up from 0 Yes and 2 Maybe; 6 of 31 needed one repair. Every No is a non-engineering role or one asking far more years.
      - On the sample posting: perfect on Flash-Lite and on qwen3.5:4B with thinking on. With thinking off, the 4B model misses "Go or Java"; that's recorded as a known issue.
    - **Student status (your request, made general):** Settings, Search has a student status (not set, currently a student, graduated), kept on this Mac with your work authorization. Prompt v2 has an `enrolment` category for requirements like "currently enrolled" or "returning to studies". When it's a must-have: graduated is a No ("Asks for a current student…"), student meets it, and not set takes it as met with a note.
    - **A rule restored:** v1's "the job's own location isn't a requirement" had been lost when location became a category. Without it, the 4B model listed "Toronto, ON" and "hybrid" as must-haves. It's back, worded for v2: only conditions on where the person must live count as location.
    - **Final reruns:** the eval is 100% precision, recall and first-write pass over 150 bullets, with no repairs. Of your postings, 26 of 31 finished before the key's daily Flash-Lite quota ran out: 4 Yes and 8 Maybe. Single verdicts move a little between runs.
    - **Floor-guard exception, approved as E1 in CONSTRAINTS.md:** four assertions pinned prompt v1 (its version, its "skill names only" message, and `matched_skill` in a reply). They're replaced with their v2 equivalents. The recorded-replay test's must-have checks for the 4B thinking-off fixture are now a known issue.
- [x] **P2 · Re-evaluate one job, re-screen all** (S) · deps: P1
  - **Acceptance:** a job's Re-evaluate runs a fresh analysis, bypassing the cache, and records the new verdict. Re-screen all applies the current settings to every job and analyses those without a current analysis.
  - **Done 2026-10-20 (core):** `ScreeningRun.reevaluate(job)` runs the prefilter with your current settings, then a fresh analysis: never the stored one, and never a cached reply (`CallContext.fresh`). It records the new verdict on top of the job's history. Re-screen all is the existing "Screen again" run. Its buttons arrive with P3's screens.
- [x] **P3 · Fetch · Review · Builds, and a full-screen Job page** (M) · deps: P1
  - **Acceptance:**
    - [x] The sidebar reads Fetch (sources, runs, what the last run dropped and why), Review (To review / Rejected / All, replacing Today and Jobs), Builds and Applications.
    - [x] A job opens full width: header, verdict and its reason, every requirement with category, match and the evidence quoted, the full posting, and Re-evaluate, Change verdict, Build resume (with cover letter), Open posting and Not for me. No side inspector.
    - [x] SPEC §4 and §5.2 and the design notes are updated; snapshots are checked in light and dark.
  - **Done 2026-10-20:**
    - **Sidebar:** Fetch, Review (badge: jobs to review), Builds, Applications; then Master resume, Settings and Activity. Sources lives in Fetch now; Today, Jobs and their inspectors are gone.
    - **Fetch:** the primary Fetch now button and Add company. Three panels: the last run, what the prefilter dropped and why (by rule, most first, e.g. "Level you've turned off 1,537"), and what's waiting for the AI. Then the sources table.
    - **Review:** the ranked table and Re-screen all. Choosing a row pushes the Job page, with Back. Split by stage at your request (2026-10-20): Yes, Maybe and No are the jobs that reached the AI (or that you overruled), grouped by country; Prefiltered is everything the prefilter dropped, grouped by the rule that dropped it, most first; All is everything, including jobs waiting for the AI. Yes and Maybe leave out what you've marked "Not for me" or applied to. The sidebar badge counts Yes plus Maybe.
    - **Job page:** company and source; title; location, arrangement and age; Open posting. The verdict card has the score, the deciding reason, who decided, and why Build waits if it does. "What the AI read" shows years, level, sponsorship, clearance, French, domains, the model and prompt version, and when. Must-haves and nice-to-haves list each requirement's category and match, with its evidence quoted from your master resume. Notes, then the posting in full.
      - Toolbar: Re-evaluate (with "Asking the AI again…"), Change verdict, Not for me, Cover letter, and the primary Build resume.
      - It shows the analysis behind the verdict whichever prompt made it (`AnalysisRepository.latest`).
    - **Visual differences:**
      - From `Main.dc.html` (closest to Review): no inspector (your decision), and To review / Rejected / All instead of Yes / Maybe / No. Fetch now moved to Fetch, and the Source column went, since the company shows in the role line.
      - From `Sources.dc.html` (closest to Fetch): the run panels are new. The side panel of titles and countries isn't here; they live in Settings, Search. The opt-in boards section waits for tier C.
      - From `PhoneJob.dc.html` (closest to the Job page): full width, actions in the toolbar rather than pinned at the bottom, and the posting shown in full rather than collapsed. Requirement rows add the category and quoted evidence.
    - **Undrawn, decided here:**
      - Partial is a half-filled circle in the Maybe amber; a requirement that doesn't count is a minus circle in secondary ink, with the words "Taken as met" or "Not judged: a personal quality". Colour never stands alone.
      - The Fetch panels reuse the grouped-surface card; the Job page is capped at 880 pt wide and centred.
- [x] **P4 · Builds never get stuck** (S), from your report of two builds frozen near the end (2026-10-20)
  - **Acceptance:** a typst run always ends, at worst at its timeout, and nothing is left running. A build that runs past its deadline fails with a clear message and frees its worker. Your two frozen builds finish.
  - **Verify:** `core-test RenderTests`, `core-test PipelineTests`; `--run-build` on a copy of your database
  - **Done 2026-10-20:**
    - **Root cause:** `TypstRunner` waited for typst with `waitUntilExit()`, which runs a run loop on a shared thread. Sometimes it missed an exit that had already happened, and waited forever. A sample of the frozen build showed that thread in `waitUntilExit` with no typst running. The 30-second timeout couldn't help: the task group it raced in waits for every child, including the stuck one. The two builds froze while rendering, the step after the cover letter for one and a fitting render for the other. Then they sat "running" for hours. Restarting the 1Password build froze it again at the same point.
    - **Runner:** the exit comes from Process's termination handler, which is set before launch. typst's messages go to a file, never a pipe that could fill, and stdin is closed. On timeout the runner stops waiting, asks typst to stop, and kills it 2 s later if it's still running. The new lifecycle tests use a fake typst that ignores the stop signal, 40 quick runs at once, and 4,000 lines of messages; against the old runner they hung.
    - **Build deadline:** a build that runs more than 15 minutes is failed ("This build ran for more than 15 minutes and was stopped. Build again to retry."). It's cancelled, and its worker takes the next build. The deadline doesn't wait on stuck work, and a step that ends late can't turn the build back to done or report more steps.
    - **Also:** builds log start, finish and failure with durations (Console, category `builds`). Render failures now read as sentences rather than enum names. A build started again after a quit replaces its earlier PDF record instead of adding a second.
    - **Checked on a copy of your database:** the 1Password build finishes in about 1 s and the Affirm stretch build in about 4 s once queued. Every render takes under 0.1 s.
    - **Found, not fixed:** in debug runs, each of the 4 Gemini keys takes 4–7 s to come out of the Keychain, about 20 s in all. The app reads keys once per launch, on the main thread, the first time it needs AI. If it's as slow there, the window freezes for that long once per launch.
- [x] **P5 · A Harvard-style resume template with contact icons** (S), your request (2026-10-21): more Harvard-like, taking the fonts, spacing, icons, underlines and italics from your reference resume (`~/Downloads/Kairos-resumes/Affirm/Software_Engineer_I_Frontend_Upfunnel/Resume.pdf`) without copying its structure
  - **Acceptance:** builds print with the new template; Classic stays available for later template choice; the PDF's text stays clean for applicant tracking systems; the cover letter matches.
  - **Verify:** `core-test RenderTests`; your reference content rendered both ways; `--run-build`
  - **Done 2026-10-21:**
    - **What the reference is:** XeLaTeX ("Jake's Resume" layout) in Latin Modern Roman, at 0.5 in margins, body 10 pt, entry titles 11 pt, small-caps headings 12 pt and the name at 24.8 pt. Its icons are drawings, so they don't show up in its text. Its text does contain 6 ligature characters ("ﬁ" as one character), which a parser can misread.
    - **What Harvard asks** (Mignone Center, Master's guide 2025): a common, easy-to-read font, no text boxes, colour or shading, 10–12 pt kept consistent, equal margins of at least ¾ in, one page for master's students. Its tech sample has a centred name, headings over a rule, organization and place on one line, and title and dates in italics on the next. Its contact line is plain text, with no icons.
    - **Measured, on the reference's own content** (19 bullets; pages of content, where over 1 means fitting drops bullets):
      - Classic: 1.22.
      - Harvard in New Computer Modern, 10 pt: 1.18 at 0.5 in, 1.21 at 0.6 in, 1.29 at 0.75 in.
      - The same at 10.5 pt and 0.5 in: 1.24.
      - Source Serif 4, 10 pt, 0.5 in: 1.17. Libertinus, same: 1.16.
      - The reference itself takes about 1.45.
    - **Decisions:**
      - **Font:** New Computer Modern, built into typst, so no new files. It's the reference's look, and its small caps are real. Source Serif 4 reads larger at the same size (x-height 0.475 em against 0.431) at the same density. It stays the alternative if Computer Modern reads too light.
      - **Size:** one body size, 10 pt, as Harvard asks; only the name (22 pt) and headings (11.5 pt) differ.
      - **Margins:** 0.6 in on every side. That's between the reference's 0.5 in and Harvard's ¾ in; ¾ in would cost about 3 lines on this content.
      - **Layout:** two-line entries, with bold role and dates over italic organization and place. Projects read "Name | *stack*". Your section order is unchanged.
      - **Links:** underlined (0.45 pt, skipping descenders), with an icon before each contact item. Italic links were rejected: italic numbers read badly in the phone number, and italics already mark organizations. Plain links were rejected because nothing then shows they can be clicked.
      - **Contact rows:** the place gets its own line, because all five items don't fit on one at 10 pt. The phone number is now a `tel:` link.
      - **Icons:** Bootstrap Icons 1.13.2 (MIT), not Font Awesome, whose icons are CC BY 4.0 and would need credit in the resume. They're inline vector drawings, marked as decoration, so neither a parser nor a screen reader meets them. Source and hashes are in `Templates/ICONS.md`.
      - **Not taken:** bolding keywords inside bullets, as the reference does. Harvard doesn't, it would need the writers to mark words, and the reference's picks ("Monitoring", "Frontend") read as keyword stuffing.
    - **Checks:** Typst's text has no ligature characters or icon symbols, and small caps keep the typed letters ("Experience", not "EXPERIENCE"). The tests prove an icon is drawn before each item, with Classic as a control that must stay under the same ink line.
    - **On your 1Password build:** fitting dropped 2 bullets to fit one page, against 1 with Classic. Most of that is the place's own line.
    - **Undrawn, decided here:** the cover letter takes the same header, at 11 pt with 1 in margins as before.
    - **Visual differences from `Build.dc.html`:** its preview is Source Serif 4 with one-line entries and caps labels. The Harvard template replaces those, as you asked; Classic still matches it.
- [x] **P5b · The Harvard template, set to Harvard's own guides** (S), your decision (2026-10-21): "Harvard preferences would precede mine". Superseded P5's choices where Harvard's guides differ.
  - **Sources:** the Mignone Center's Master's resume guide (2025), the College bullet template (2025 `.docx`), its resume sample and optional category examples (2026), and its quick tips. Conflicts were settled this way: written rules beat samples, and the master's guide beats the College one, since you hold a master's.
  - **Harvard's rules applied:**
    - **Font:** "a common, easy to read font". That's Liberation Serif, metric-compatible with the Times New Roman of Harvard's sample, at 11 pt. Times New Roman itself can't be bundled.
    - **Size:** one size "kept consistent throughout", the name and headings included (as in the master's tech sample).
    - **Margins:** "equal all the way around … at least three quarters of an inch". 0.75 in.
    - **Colour:** none, and no boxes or shading.
    - **Abbreviations:** "Don't abbreviate". Months are spelled out, and a range within one year names the year once ("May – August 2025").
    - **Order:** "For tech (computer science) resumes, include Technical Skills after the Education section". So Education, Skills, Experience, Projects, Certifications, with spoken languages as Harvard's "Language" row under Skills.
  - **Taken from Harvard's samples:**
    - The name in bold capitals.
    - One contact line: place, phone, email, links, with " | " between them.
    - Headings in bold capitals over a rule.
    - Organization (bold) and place, then title (italic) and dates.
    - Education shows school and place, then the degree and its graduation date.
  - **No summary:** no Harvard template, sample or optional category has one. A Harvard build doesn't write one, which saves an AI call, and the score doesn't count it.
  - **Dropped from P5:** the icons, the underlines and the small caps. No Harvard sample has them.
  - **Kept, where Harvard is silent:** the links show the address (`linkedin.com/in/…`), not just "LinkedIn", so they still work on paper and for parsers. The phone number stays a `tel:` link.
  - **Cost:** your content needs 1.31 pages at 11 pt; Harvard's ¾ in margins are the main cost. It's 1.17 at 10.5 pt, which is still inside Harvard's 10–12 pt; that's a one-line change in `ResumeTemplate.harvard.style`.
  - **Design:** `ResumeDocument(_:for:)` makes Harvard's choices in Swift (tested without typst), and documents carry their template. `BuildQueue(template:)` defaults to Classic, which its existing tests cover unchanged; the app passes `.standard`.
  - **Tests:** one size throughout; margins equal and at least ¾ in; the Times-style font only; the reading order; the plain contact line keeping its links; Harvard's arrangement and dates; no summary call in a Harvard build.
  - **Cover letter:** the same font and contact line. The name stays as typed, in bold, because Harvard's letter template sets no letterhead. Harvard's own letter template greets with a colon ("Dear …:"), but the greeting is unchanged, since your request was about the resume.
- [x] **P5c · Dates both Harvard-like and exact for parsers** (S), from your question about education showing only a year (2026-10-21)
  - **Findings:**
    - Textkernel (formerly Sovren), the parser behind many ATS, stores dates as full dates: "if the day and/or month could not be found, they will be 01". So "2025" became 1 January 2025, seven months off for your master's.
    - Workday-style forms have Education "From" and "To" fields, which an employer may require. With a year alone, "From" stays empty and "To" may show January.
    - "2025" alone wasn't Harvard's doing. Kairos has printed education as years since T35, and Harvard's own sample prints "May 2027".
    - P5b's shortened same-year range ("May – August 2025") left the start without a year. A parser may misread that and miscount months of experience.
  - **Done:**
    - Every build entry keeps its dates as numbers (`TailoredResume.Period`) next to the text. The Harvard layout writes them out with a year on every month: "January 2024 – August 2025", "September 2024 – Present", "March 2024".
    - Same-year ranges are no longer shortened.
    - A degree whose end month is after the build is marked as Harvard writes it: "September 2024 – May 2026 (Expected)". The word goes after the range, so a parser still reads two dates. Before, it read as finished. Jobs keep their dates.
    - Older builds, which have only text, get their months spelled out, and a year alone stays a year.
    - Classic and its tests are unchanged: the text is the same as before.
  - **Checked on a copy of your database:**
    - Education: "January 2024 – August 2025; April 2019 – April 2023".
    - Experience: "May 2025 – August 2025; March 2024 – December 2024; December 2022 – May 2023".
  - **Found in your data, not changed:**
    - The project chosen for that build reads "October 2026 – Present". Projects imported from GitHub take the repository's creation date, so a project you pushed this month looks brand new.
    - One certification reads "October 2026". It may be real, or the editor's default, since picking a month with no year fills in this year.
    - Both are in Master resume, under each entry's dates.
- [x] **P6 · Keys in a private file until release** (S), your decision (2026-10-21): "remove the keychain for now … until the final release and at that time you can ask me to put it again"
  - **Why:** the login keychain kept asking for your password on reads, despite the stable signing certificate added at the start of polish (7e574bd). Each debug build run I made read your 4 Gemini keys, and each read took 4–7 s, about the time it takes to type a password. So those runs likely prompted you.
  - **Done:**
    - `FileSecretStore` keeps keys in `api-keys.json`, in Kairos's sandbox folder next to the database folders.
    - The file is readable only by your account (0600), even after a rewrite. It's left out of Time Machine backups, never synced and never in SQLite. A damaged file is an error rather than an empty store, so a save can't wipe it.
    - The app and the debug runs read keys only from there (`AppSecrets.store()`) and never touch the Keychain.
    - The Keychain store and its signing spike stay in the code for release.
  - **Your step:** paste your keys again in Settings, AI providers. Each saved key name with nothing behind it shows "Not on this Mac" and an Add button. Your old Keychain items are left as they were; you can delete them in Keychain Access, or keep them until release.
  - **Checked:** a debug build run read all 4 keys from the file in 0.0 s and queued in 0.3 s, against about 20 s before, with no Keychain access.
  - **Release:** recorded on T57: ask you before moving keys back, and find the cause of the prompts first. SPEC §5.7 and §12 note the exception.

- [x] **P7 · "Posted within" applies while fetching** (S), your request (2026-10-22): "only fetch jobs which are posted x days ago … instead of prefiltering them … have the option baked while fetching"
  - **Before:** Settings, Search had "Skip postings older than N days" (7 to 180, in weeks). Every posting was fetched and stored, then the prefilter rejected the old ones, so they filled Prefiltered. Only Adzuna asked for the limit in its search.
  - **Done:**
    - **Fetch screen:** a "Posted" menu next to Fetch now: Any time, past day, 3 days, week, 2 weeks, month, 2 months. It's the same setting, so your current value carries over, and a value set before (28 days, say) stays a choice. It's gone from Settings, Search.
    - **While fetching:** postings older than the limit are dropped before they're stored, for every source. One with no date is kept, since its age can't be told. The run records how many it skipped (nil when none, so older run records read as before), and Fetch's summary says "N older ones skipped".
    - **The prefilter rule stays** for jobs stored before the limit or before this change, when they're screened again.
  - **Tests:** a fetch with a 7-day limit stores postings 3 and 7 days old and one undated, skips one 10 days old, and records it. The other fetch tests are unchanged.

- [x] **P8 · The jobs flow, rethought for any job seeker** (M), your request (2026-10-22)
  - **Your outline:**
    - Company boards, then Adzuna.
    - A "Delete all jobs" feature.
    - Recent jobs only: done as P7.
    - A sidebar item for prefiltered jobs, by reason with All.
    - Review holding only the rest, as Yes, Maybe, No and All, with Re-screen all.
  - **Research and proposal:** [Kairos Jobs Flow](https://claude.ai/artifact/QmmhHEko15JGmWnRY9cJHS) covers job-seeker data, similar tools and six user types, checks your flow against the code, and has mockups and alternatives.
  - **Your decisions:**
    - Tech and nearby roles first.
    - After Delete all jobs, still-posted jobs come back on the next fetch.
    - Jobs you've acted on are dimmed in All only.
    - Jobs older than the Posted window stay in Review until retention archives them.
  - **Done:**
    - **Sidebar:** Find jobs, Review, Filtered out, Resumes, Applications; then Master resume, Settings, Activity. Find jobs and Resumes are the plain names for Fetch and Builds. Review's count is Yes plus Maybe; Filtered out shows its total.
    - **Review:**
      - Only jobs that passed your filters. Yes, Maybe and No leave out jobs you've applied to or marked "Not for me". All adds those, dimmed and labelled, plus jobs waiting for the AI.
      - A banner says how many jobs wait for the AI, and how to fix it.
      - Re-screen all first says how many AI calls it needs (jobs without an analysis from the current prompt) and asks before spending them.
    - **Filtered out:**
      - Reasons with their counts down the left, under All. The chosen reason's setting shows in words, with "Change in Settings", which opens Search.
      - Each job has "Bring back": Kairos remembers it in a synced setting of job ids, and the filters never drop it again. It's judged by its stored analysis or the AI, or waits for the AI.
      - "Re-check filters" applies your filters to every job without AI calls. A job with a stored analysis gets its verdict from it, and one newly let through waits.
    - **Delete all jobs:** in Find jobs' More menu.
      - It says how many it deletes, and that the jobs you saved, built a resume for or applied to stay.
      - Deleted jobs become cleared tombstones (`009_cleared_jobs.sql`), with their analyses and screening trail. A cleared job isn't known, so the next fetch brings back what's still posted, screened afresh.
      - Retention's tombstones aren't cleared, so old postings still never return.
    - **Screening without the AI:** a stored analysis now decides even with no AI set up. Before, a run without a key left every job waiting.
    - **Wording:** "prefilter" is gone from the screens in favour of "your filters" and "Filtered out".
  - **Tests:**
    - 3 for Delete all jobs: what's kept, a cleared job coming back as new, retention's tombstones staying known.
    - 3 for screening: a stored analysis deciding without the AI, Bring back surviving a re-screen, Bring back waiting without the AI.
    - Snapshots of Review, Filtered out and Find jobs, light and dark.
  - **Visual differences from the mockups in the proposal:**
    - The sidebar counts use macOS's own sidebar badges, so Review's count isn't a filled accent capsule.
    - Bring back is a plain button in a table column.
    - Delete all jobs uses the system confirmation dialog, without the radio choice: you chose one behaviour.
  - **Undrawn, decided here:** the reasons list is a sidebar-style list beside the table. The rule bar reuses the grouped surface. The waiting banner uses `maybe-bg` with an hourglass icon and words.
  - **Proposed next, from the research:**
    - A company finder by name, so nobody has to hunt for career-page links.
    - A guided first run.
    - Filters shown above the Review list.
    - Revisiting a daily check with a notification (T44): applications in a posting's first 96 hours get up to 8 times the interviews.

## Phase 2: R2 Daily driver (refined at Checkpoint E)

Refined with you on 2026-10-21:
- **Order:** T40 Adzuna, T45 application tracking, T41–T43 page runners, T46 retention, then T44.
- **T44 (scheduler, menu bar, login item, notifications):** last, and possibly dropped. You don't want it now; it's up for debate.
- **T41–T43 (page runners):** first kept, opt-in. **Dropped on 2026-10-22, your decision**, after a check:
  - Indeed Canada sits behind Cloudflare's bot check. A background WebKit view stayed on "Just a moment…" for 30 s, and a plain request got HTTP 403.
  - Kairos won't work around a bot check.
  - Indeed, LinkedIn and Job Bank all forbid automated access in their terms. Job Bank's, for one, bars "any script, robot, spider, Web crawler, screen scraper…".
  - Company boards and Adzuna stay the sources.

- [x] **T40 · Adzuna source, Canada first** (S) · deps: R1
  - **Acceptance:** queries `ca` before `us`; the key is in the Keychain (in the private key file until release, P6); stays under the documented limits.
  - **Refined 2026-10-21:**
    - **Snippets:** Adzuna's API returns a snippet of each posting, not the whole text. Kairos never follows an advert's link itself, because Adzuna's advertisers pay for those clicks.
    - **Screening:** a snippet can rule a job out but not make it a Yes; a strong match is capped at Maybe.
    - **Duplicates:** company boards run before Adzuna, so a job on both keeps the board's full posting.
    - **Credit:** Adzuna's terms ask that listings name it, linked.
  - **Verify:** `core-test JobSourcesTests`
  - **Done 2026-10-21:**
    - **`AdzunaSource`:** one search per title in Settings, Search (`title_only`), newest first, 50 a page, using your posting-age limit. Countries go in your order, Canada first.
    - **Limits:** at most 20 searches a fetch. The free plan allows about 25 a minute and 250 a day.
    - **Cleanup:** Adzuna's highlighting tags and entities are removed. The same advert found by two titles is kept once. An advert keeps one identity across runs, because its link's tracking (`se`, `v`, `utm_*`) changes on every search.
    - **Errors:** a wrong app ID or key reads as a settings problem, and the key never appears in a message.
    - **Fetch:** a fetch runs company boards first, then search sources (`SourceKind.isSearch`).
    - **Screening:** Adzuna's jobs are snippets. A strong match is a Maybe with the reason "Only a snippet of this posting came from Adzuna…", and a snippet naming no skills says the same. A weak match, French or a clearance can still make it a No.
    - **App:** Fetch's Add menu has "Company board…" and "Adzuna search…".
      - The Adzuna sheet takes the app ID and key, with a link to get a free key and Adzuna's credit.
      - The keys go in the private key file, and are deleted when you remove the search.
      - Its row reads "Your job titles", with "Change Adzuna keys…" in its menu.
      - A job from Adzuna shows "Jobs by Adzuna", linked, and the snippet note under its verdict.
    - **Tests:** 7 for the source and factory on recorded responses (fictional companies), 1 for the fetch order, 2 for the snippet cap. Snapshots of the sheet and the job page, light and dark.
    - **Undrawn, decided here:** the sheet follows Add company (title, explanation, labelled fields, notes with icons, links, then Cancel and Save). The credit is an accent link beside the company name; the snippet note is a secondary-ink line with an icon, like the Build-blocked note.
    - **Visual differences from `Sources.dc.html`:** its opt-in boards section isn't drawn for Adzuna. Adzuna is tier B, on once you add your keys, so it sits in the source list with the company boards.
    - **Your step:** get a free app ID and key at developer.adzuna.com, then Fetch, Add, Adzuna search…. Your job titles must be in Settings, Search.
    - **Not done:** a board copy of a job first stored from Adzuna in an earlier run doesn't replace it yet. Within one run the board's copy wins.

- [-] **T41 · WebKit page runner and Indeed Canada** (M) · deps: R1 · **dropped 2026-10-22** (see above)
  - **Acceptance:** offscreen `WKWebView`, a data store per source, a JavaScript extractor contract, timeouts and health tracking. The Indeed Canada extractor passes on saved HTML fixtures.
  - **Verify:** `core-test JobSourcesTests`; manual run

- [-] **T42 · LinkedIn, Job Bank and Indeed US extractors** (M) · deps: T41 · **dropped 2026-10-22**
  - **Acceptance:** one fixture test each; a board goes "degraded" after 3 empty runs.
  - **Verify:** `core-test JobSourcesTests`

- [-] **T43 · Opt-in and login sheets for page-runner boards** (S) · deps: T41 · **dropped 2026-10-22**
  - **Acceptance:** the warning appears before opting in; login happens in a visible WebKit sheet; cookies persist per board. Styled after the opt-in section of `Sources.dc.html`.
  - **Verify:** `app-build`; manual

- [ ] **T44 · Scheduler, menu bar, login item, notifications** (M) · deps: R1
  - **Acceptance:** a daily run at the set time while the menu bar app runs; launch at login; one notification with yes and maybe counts.
  - **Verify:** `app-build`; manual over two days

- [x] **T45 · Application tracking** (M) · deps: R1
  - **Acceptance:** `008_applications.sql`; status board; append-only timeline; notes; follow-up reminders as notifications.
  - **Verify:** `core-test StoreTests`; `app-build`
  - **Done 2026-10-21:**
    - **`008_applications.sql`:** `application` and `application_event`, both STRICT and syncable, with one application per job.
    - **`ApplicationRepository`:** applying records when, where (the job's board, "Greenhouse") and with which build (the one on screen, else your latest finished one). It starts the timeline with "Applied" and marks the job applied; applying twice changes nothing. Every status change appends a timeline line with your note, and nothing edits one. Statuses: applied, screen, interview, offer, then closed as accepted, not selected, no reply or you withdrew. Deleting asks first, tombstones the application and its timeline, and puts the job back to new.
    - **App:** Applications is a board with Applied, Screen, Interview, Offer and Closed columns. Each card shows its company, role, and either its status date or a follow-up ("Follow up today" in amber with a bell, never colour alone). Choosing one opens it full width:
      - links to open the job and the posting, and where it stands with a Move to menu;
      - a follow-up, with what to do and when, delivered as a macOS notification even when Kairos is closed (permission is asked when you set the first);
      - the timeline, with "Add to the timeline" for calls and notes;
      - notes, saved a second after you stop typing.
    - **Mark applied:** on the Job page, and on the Build screen, which records that build.
    - **Tests:** 6 store tests (tables, applying, timeline order, follow-up and notes, ordering, deleting). Snapshots of the board and an application, light and dark.
    - **Visual differences from `Applications.dc.html`:**
      - An application opens full width, not in a side panel, as you asked for jobs in P3.
      - It has one follow-up rather than a list: SPEC's model has one `next_action_at`, and a list can come later if one isn't enough.
      - There's no "Add application" for jobs Kairos didn't find yet.
      - No avatar, sidebar counts or sync time; those wait for accounts.
    - **Undrawn, decided here:** the status card reuses the grouped surface with a Move to menu. Timeline lines take each status's symbol. The follow-up row is a text field, a date and time, and Set reminder or Change and Clear.

- [x] **T46 · Retention and `kairos doctor`** (S) · deps: T45
  - **Acceptance:** archive after 60 days and tombstone after 120 for jobs never shortlisted; integrity checks report orphans.
  - **Verify:** `core-test StoreTests`
  - **Done 2026-10-22:**
    - **`Retention`:** a job you never saved, applied to or built a resume for (new, skipped or archived) is archived 60 days after Kairos first saw it. At 120 it's tombstoned, with its analysis and screening trail.
      - Tombstones stay known, so a posting still up isn't added back as new or analysed again.
      - It runs at the end of every fetch. The run records what it archived and removed (nil when nothing, so older run records read as before), and Fetch's summary says "N old jobs tidied away".
      - Archived jobs stay out of Review's Yes and Maybe; the other filters still list them.
    - **`Doctor`:** reports rows pointing at something gone (analyses, screening records, builds, applications and their timelines, build files, resume bullets) and build files missing from disk, plus the database's size. It changes nothing, and checks only the tables a database has, so an older database works.
    - **The `kairos` command line:** comes with R3, and `kairos doctor` will print this report. Until then, `Kairos --doctor` (debug builds) does.
    - **Your database (2026-10-22):** 24.2 MB, no problems found.
    - **Tests:** retention by age, state, build and application, with its trail removed and the job still known; doctor on a clean, damaged and older database; the fetch ends by retiring.

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
  - **Before this ships, ask Kenee:** move API keys back into the Keychain (P6, your decision on 2026-10-21). First find out why the login keychain kept prompting despite the stable signing certificate, so the move doesn't bring the prompts back. Then switch `AppSecrets.store()` back to `KeychainStore`, move the keys out of `api-keys.json` and delete that file.
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
