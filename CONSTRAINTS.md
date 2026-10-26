# Constraints

Last reviewed: 2026-10-18 by Kenee Patel. Drafted from `SPEC.md` §14 using the constraint-driven-development defaults, which were shown and unchanged across three spec reviews.

Read this before writing code. Do not weaken it to make a change pass. Tightening a rule needs no discussion; loosening one needs the owner's approval in the pull request.

## Floor (always enforced, no setup required)

- No new suppression comments or flags: `// swift-format-ignore`, `gitleaks:allow`, `-suppress-warnings`, or `unsafeFlags(["-w"])` in `Package.swift`.
- No unfinished work in non-test code: `try!`, `fatalError("not implemented")`-style stubs, empty `catch {}` blocks, or `TODO` standing in for an implementation. Force unwraps are caught by swift-format's `NeverForceUnwrap` rule outside tests.
- No skipped or deleted tests without a reason in the commit message. That covers `.disabled(` traits, `XCTSkip`, deleted test files, and `#expect` / `#require` / `XCTAssert` calls removed from tests that remain.
- No secrets in source, fixtures, logs or test output.
- No new Swift packages, bundled binaries or npm packages without approval.
- Every commit is authored and committed by Kenee Patel <patelkenee2804@gmail.com>, with no AI attribution trailers (see `AGENTS.md`).
- This file does not get weakened to make a change pass.

## Enforced with numbers

| Dimension | Rule | Checked by | Runs at |
|-----------|------|-----------|---------|
| Format | Zero findings | `swift format lint --strict --recursive Packages App` | Every change, CI |
| Warnings | Zero warnings in Swift 6 language mode | `swift build --package-path Packages/KairosCore -Xswiftc -warnings-as-errors` | Every change, CI |
| Tests | All pass with networking blocked | `swift test --package-path Packages/KairosCore` | Task end, CI |
| Coverage | Changed lines ≥ 80% covered in `Store`, `MasterResume`, `LLM`, `Screening`, `Tailoring`, `Account`, `Sync` | `swift test --package-path Packages/KairosCore --enable-code-coverage` then `scripts/coverage-diff.sh` | Task end, CI |
| Floor guard | Exit 0 | `swift scripts/floor-guard.swift --base origin/main` | Task end, CI |
| Dependencies | 0 resolved Swift packages; bundled binaries = `typst` only; no npm packages in `Web/` | `scripts/check-deps.sh` | Every change, CI |
| Design tokens | No hard-coded colours: no hex literals, `Color(red:` or `NSColor(` values in `App/`, and no hex in `Web/` outside the generated tokens file | `scripts/check-design.sh` | Every change, CI |
| Commits | Author and committer = Kenee Patel; no trailers. Pull requests from other contributors: no AI attribution (`--allow-other-authors`) | `scripts/check-commits.sh origin/main..HEAD` | Before push, CI |
| Secrets | No findings | `gitleaks detect --redact --no-banner` | Before commit (if installed), CI |
| Backend isolation | All tests pass on the staging project | `KAIROS_LIVE_SUPABASE=1 swift test --package-path Packages/KairosCore --filter BackendIsolation` | Before any production `supabase db push` |
| Prompt evals | Must-have extraction ≥ 0.85 precision and ≥ 0.80 recall; first-write verifier pass rate ≥ 95% | `KAIROS_LIVE_LLM=1 swift test --package-path Packages/KairosCore --filter PromptEvals` | Any built-in prompt or default-model change |
| App size | ≤ 80 MB | `du -sh build/Kairos.app` | Release |
| Launch time | ≤ 1.5 s to an interactive window on an M1 | Instruments, App Launch template | Release (manual) |

Every row names the command that produces its verdict. Gitleaks is the external check here: its rules come from outside this repo, so passing it can't be arranged by the code under test.

**Why these numbers.** Changed-line coverage of 80% forces a test for real logic while allowing an untested config line. The eval thresholds are set so a prompt change can't quietly make requirement extraction worse. Bundle size and launch time are the spec's targets (§13, S11).

## Measured, not yet enforced

| Metric | Today | Direction |
|--------|-------|-----------|
| Project line coverage (KairosCore) | 87.2% of 570 lines (2026-10-19, T09). The gated live keychain test is off in this run, so `Secrets` shows 24% | Must not fall (tolerance 0.5%) |
| App bundle size | 43 MB on disk, debug build with typst bundled (2026-10-19, T06) | Must not grow by more than 5 MB in a release without a stated reason |

## Exceptions

| ID | Rule | Path | Reason | Owner | Expires |
|----|------|------|--------|-------|---------|
| E3 | Floor guard: assertion-removed (1 line) | `Packages/KairosCore/Tests/JobSourcesTests/OptionalSourcesTests.swift` | Approved by you 2026-10-26 (job collection v3, C1). The Google Jobs test asserted that a job's address starts with Google's search page (`share_link`), the bug v3 fixes: the address is now the page Google took the posting from, and the test asserts that instead. | Kenee Patel | When `collection-v3-c1` merges into `main` |
| E4 | Floor guard: assertion-removed (20 lines in six test files) | `Packages/KairosCore/Tests/{PipelineTests/InboxTests,PipelineTests/FetchRunTests,PipelineTests/ImproveReportTests,PipelineTests/LeadFinderTests,ScreeningTests/VerdictRankingTests,JobSourcesTests/OptionalSourcesTests}.swift` | Approved by you 2026-10-26 (job collection v3, C2). The assertions pinned snippet behaviour that ADR-018 removes: the Inbox's "Needs a full read" group, the `snippet_only` verdict and the screening context's snippet sources, a snippet filled in from a board, Adzuna's copy counted as a duplicate. Each is replaced by a test of the new behaviour (leads, two groups, a board read behind a lead). | Kenee Patel | When `collection-v3-c2` merges into `main` |

## Where each check runs

| Stage | What runs | Budget |
|-------|-----------|--------|
| After an edit | Format lint on changed files, package build with warnings as errors | Under 30 s |
| Task end | Tests, coverage of changed lines, floor guard, dependency check | Under 90 s |
| Before push | Commit check, gitleaks | Under 10 s |
| CI (every pull request) | Everything in the "every change", "task end" and "before push" rows | Minutes |
| Release | App size, launch time, backend isolation (if migrations changed) | Minutes |
