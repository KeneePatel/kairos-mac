# Contributing

Thanks for helping. Kairos is small and opinionated, so please read these before opening a pull request.

## Before you start

- Read [`SPEC.md`](SPEC.md) for what the app does and the decisions behind it, and [`CONSTRAINTS.md`](CONSTRAINTS.md) for the quality bar.
- For anything you can see, read [`design/kairos/README.md`](design/kairos/README.md). Colours, type, spacing and radii come only from `design/kairos/tokens.json`.
- For a larger change, open an issue first so we can agree on the approach.

## Rules

- No new Swift packages, bundled binaries or npm packages without agreement in an issue first.
- Never commit secrets, API keys or signing material.
- Keep the sample data (Jordan Rivera and the mockup companies) in previews and test fixtures only.
- Resumes may only claim what's in the user's master resume, except in the opt-in Stretch mode described in the spec. Don't weaken the claim verifier.

## Checks

Run these before pushing. CI runs the same checks, and every pull request must pass them:

```bash
swift format lint --strict --recursive Packages App
swift test --package-path Packages/KairosCore
scripts/check-deps.sh
```

The full list is in `CONSTRAINTS.md`.

## Pull requests

- Keep each pull request to one change, with a clear description of what and why.
- Add or update tests for any behaviour you change.
- Link the spec section or task (`tasks/todo.md`) your change implements.
