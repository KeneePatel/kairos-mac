# Developing Kairos

## Set up

- macOS 26 on Apple silicon, Xcode 26 or later (Swift 6.2 or later), and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).
- Fetch the pinned Typst binary (checksum verified) into `Vendor/typst/`:
  ```bash
  scripts/fetch-typst.sh
  ```
- Generate the Xcode project (it's git-ignored):
  ```bash
  (cd App && xcodegen generate)
  ```
- To sign builds with a stable identity, so the keychain and the app's container keep trusting new builds, follow [`signing.md`](signing.md).

## Everyday commands

```bash
swift test --package-path Packages/KairosCore
swift format lint --strict --recursive Packages App
xcodebuild -project App/Kairos.xcodeproj -scheme Kairos -destination 'platform=macOS,arch=arm64' build
scripts/check-deps.sh
```

Before pushing, the rest of [`CONSTRAINTS.md`](../../CONSTRAINTS.md):

```bash
scripts/check-design.sh
scripts/coverage-diff.sh origin/main
swift scripts/floor-guard.swift --base origin/main
scripts/check-commits.sh origin/main..HEAD
```

`swift format format --in-place --recursive Packages App` fixes most lint findings. After changing `design/kairos/tokens.json`, run `swift scripts/gen-tokens.swift` and commit the asset catalog and `App/Kairos/Design/DesignTokens.swift` it writes.

## The `kairos` tool

The engine without the windows, over any data folder. Use a scratch folder to try a change against live boards and models without touching your own data:

```bash
swift build --package-path Packages/KairosCore --product kairos
```

```bash
Packages/KairosCore/.build/debug/kairos set screening '{"roles":["software"],"countries":["CA"],"maxAgeDays":30}' --data /tmp/k
```

```bash
Packages/KairosCore/.build/debug/kairos fetch --data /tmp/k
```

Commands: `status`, `fetch`, `screen [--everything] [--limit n]`, `jobs [--list inbox|saved|skipped|filtered|waiting]`, `show <job id>`, `build <job id> [--mode strict|lite|stretch] [--letter]`, `sources`, `add <system> <slug>`, `set <key> <json>`, `import`, `backup`, `doctor`. Point `KAIROS_TYPST` (or `--typst`) at a typst binary for builds; from the repository it finds `Vendor/typst/typst` on its own.

For screening against a model on your Mac, set the `llm` setting to Ollama:

```bash
Packages/KairosCore/.build/debug/kairos set llm '{"providers":[{"id":"ollama-local","presetID":"ollama-local","keyNames":[]}],"routes":{"analyzeJob":[{"provider":"ollama-local","model":"qwen3.5:4B"}]},"budget":{"dailyCalls":500}}' --data /tmp/k
```

## Live AI checks

`scripts/live-llm.sh` reads a Gemini key from your Keychain (service `com.keneepatel.kairos.dev`, account `gemini`) into the test process only; it never prints it.

```bash
scripts/live-llm.sh LiveAdapter
```

```bash
scripts/live-llm.sh PromptEvals
```

`PromptEvals` makes about 60 calls, writes `evals/<date>-<model>.json` and records the replies under `Packages/KairosCore/Tests/Fixtures/evals/replies/`, which the offline replay then scores on every test run. Run it after any prompt or default-model change (CONSTRAINTS.md, "Prompt evals").

## Debug tools in the app

Debug builds take two arguments, then quit:

- `--snapshots` renders every screen, light and dark, over sample data (Jordan Rivera and the design's companies) and prints each PNG as base64 lines `SNAPSHOT <name>.png <data>`: the sandbox keeps the app's files from the terminal. Decode them with a few lines of Python and compare with `design/kairos/screens/`. The sidebar's glass and the toolbar don't render offscreen, and an inactive window draws switches and the prominent button grey.
- `--import-check` copies the first Kairos's database from the app's container into a temporary folder, imports the copy, prints the report and counts, and deletes the copy. Your files are only read.

```bash
/path/to/Debug/Kairos.app/Contents/MacOS/Kairos --import-check
```

## Logs

The app logs to the unified log under the subsystem `com.keneepatel.kairos`, with ids and counts only:

```bash
log stream --predicate 'subsystem == "com.keneepatel.kairos"'
```
