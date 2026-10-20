# Prompt evals

Reports from `PromptEvals` (SPEC §5.5, CONSTRAINTS.md "Prompt evals"), committed so a prompt or
default-model change can be compared with the last run.

## Run

```bash
scripts/live-llm.sh PromptEvals
```

It reads your Gemini key from the Keychain (never printed) and makes about 60 calls: `analyzeJob`
and `writeExperience` for each of the 30 labelled postings in
`Packages/KairosCore/Tests/Fixtures/evals/postings.json`. Both default to Flash-Lite, so the free
tier's small Flash allowance isn't spent; choose others with `KAIROS_EVAL_MODEL` and
`KAIROS_EVAL_WRITER_MODEL`.

## What it measures

| Measure | How | Must be at least |
|---|---|---|
| Must-have precision | Predicted must-haves that match a hand label, over all predicted must-haves | 0.85 |
| Must-have recall | Hand labels some predicted must-have matches, over all labels | 0.80 |
| First-write pass rate | Experience bullets passing the strict verifier in the writer's first reply (no repair), over all bullets | 0.95 |

A prediction matches a label when they share a technology (`Synonyms.json`) or most of the words
of one appear in the other. Labels include conditions such as work authorization and French, since
`analyzeJob` reports those as must-haves too.

## Reports

`<date>-<model>.json` holds the three numbers, whether they meet the thresholds, and for each
posting the predicted must-haves, the wrong ones, the labels missed, and every verifier finding on a
bullet. Rerun and commit a new report whenever a built-in prompt or a task's default model changes
(SPEC §12, "Ask first").
