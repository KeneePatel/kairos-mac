# Spike T20: structured output from Gemini and Ollama

**Date:** 2026-10-19 · **Harness:** `Packages/KairosCore/Tests/LLMTests/LiveStructuredOutputTests.swift` · **Replies:** `Packages/KairosCore/Tests/Fixtures/llm/` · **Offline checks:** `RecordedRepliesTests.swift`

**Question:** for each provider preset, does asking for JSON through `response_format` work, and do the replies pass our own schema check? The answer sets the capability flags T21's presets carry.

**Method:** one fictional sample posting (Northline Freight, design sample data), one small schema: requirements as `{text, kind: must|nice}`, `years_required`, and `remote`. Each reply was validated with `SchemaValidator` and scored against a hand labelling of the posting: 4 must-haves and 3 nice-to-haves.

## Results

| Preset · model | Mode | HTTP | Schema check | Requirements (precision / recall) | Output tokens | Time |
|---|---|---|---|---|---|---|
| Gemini · `gemini-flash-lite-latest` | `json_schema` (strict) | 200 | valid | 1.0 / 1.0 | 97 | under 1 s |
| Gemini · `gemini-flash-lite-latest` | `json_object` | 200 | valid | 1.0 / 1.0 | 208 (pretty-printed) | under 1 s |
| Gemini · `gemini-flash-latest` | `json_schema` (strict) | **503** "high demand" (temporary) | — | — | — | — |
| Gemini · `gemini-flash-latest` | `json_object` | 200 | valid | 1.0 / 1.0 | 96 shown + **504 hidden thinking** | under 1 s |
| Gemini · `gemini-omni-1.1-flash` (first run's wrong pick) | both | 429 | — | — | — | — |
| Ollama 0.40 · `qwen3.5:4B` (nvfp4) | `json_schema` and `json_object` | **501** "structured output is unavailable" | — | — | — | instant |
| Ollama · `qwen3.5:4B` | no `response_format`, thinking on | 200 | valid | 1.0 / 1.0 on one run; 1.0 / 0.71 on another (merged three nice-to-haves into one item) | 1,904–2,669 | 92–117 s |
| Ollama · `qwen3.5:4B` | no `response_format`, thinking off (`reasoning_effort: none`) | 200 | valid after removing a code fence | 0.875 / 1.0 on one run (listed the job title as a requirement); 1.0 / 1.0 on another | 221–239 | 10–11 s |

**Second run (same day):** the fixed picker chose Google's `gemini-flash-latest` alias. The first run had sorted names and chosen `gemini-omni-1.1-flash`, which has a free-tier quota of 0. Flash's schema mode met a temporary 503 ("high demand"), so it's the one cell left unmeasured; Flash-Lite shows the endpoint's schema mode works. Gemini lists 63 models, including `gemini-flash-latest` and `gemini-flash-lite-latest` (saved in `gemini-models.json`, ids only). Ollama's replies were identical to the first run's apart from ids: at temperature 0 the thinking-mode merge reproduces.

**Re-check through the real adapter and client (T20a, same day, `LiveAdapterTests`):**

| Model | Mode | Result | Calls | Output tokens | Time |
|---|---|---|---|---|---|
| `gemini-flash-latest` | strict `json_schema` | valid, 7 of 7 requirements, nothing extra | 2 (the first failed and the client retried) | 588 (about 96 shown + hidden thinking) | 54 s |
| `gemini-flash-lite-latest` | strict `json_schema` | valid, 7 of 7 | 1 | 97 | 0.85 s |
| Ollama `qwen3.5:4B` | prompt-only, learned from its 501; thinking off | valid; lists the job title as a requirement (T28's prompt fixes it) | 1 | 98 | 8.5–13 s |

That fills the last cell: Gemini Flash does strict schema mode. The client counted hidden thinking as output, as designed. The run's output doesn't say why Flash's first try failed; a temporary 503 (seen in T20) and a rate limit are both handled.

**Larger schemas (T25 follow-up, 2026-10-19, `importResume`):** Gemini refused the resume-import request in strict mode with a bare HTTP 400 "Request contains an invalid argument", with no mention of the schema. Bisected live on `gemini-flash-latest`, one change at a time:

| Request | Result |
|---|---|
| full schema, strict | 400 (also with 1,500 output tokens) |
| full schema, `json_object` | 200 |
| full schema without `maxItems`, strict | 200 |
| full schema without `maxLength`, strict | 400 |
| no limits at all, strict | 200 |
| header fields only (string lengths, a number range, no lists), strict | 200 |
| experience only; education only; skills and education; the optional lists only, strict | 400 each |

`gemini-flash-lite-latest` refuses the same request the same way. The cause is item counts on lists: Gemini's strict mode turns them into a grammar that grows with the count, and it rejects the result without saying why. The small `analyzeJob` and `importGitHubRepo` schemas (counts of 12 and 4) were under that limit.

**Fix:** strict schema requests leave out `maxItems` (`JSONSchema.withoutItemCounts`), for every provider. `SchemaValidator` still checks counts on every reply, and the repair call handles a reply that breaks them. JSON and prompt-only modes still show the full schema in the prompt. After the fix, the whole import on Flash-Lite was valid on the first call (4.3 s, 1,205 output tokens).

The bisection used about 14 of Flash's 20 free requests a day: the free tier's daily cap (`limit: 20`, "retry in 8h") is a real constraint on live testing.

## Capability flags for T21

| Preset | Structured output | Notes |
|---|---|---|
| Gemini (OpenAI-compatible) | **schema** | Strict `json_schema` works, without `maxItems` (larger schemas with item counts are refused). It also uses half the tokens of `json_object`, which pretty-prints. |
| Ollama local | **learned per model**, default **prompt-only** | Some builds refuse every `response_format` with HTTP 501. The adapter must resend without it and remember the model's answer. |
| Ollama Cloud, Groq, OpenRouter, OpenAI | unmeasured | Start as schema; same 501/400 downgrade path. |

## What this changes

1. **Capability is per model, not per preset.** Ollama's API accepts `response_format`, but this model build refuses it. T21 records a per-(provider, model) flag that starts at the preset default and drops to prompt-only on that refusal.
2. **HTTP 501 is not retried.** "structured output is unavailable" means resend once without `response_format`; retrying it as a 5xx (SPEC §5.5) can never succeed. T21 maps it; T22 doesn't retry it.
3. **Gemini errors arrive wrapped in an array** (`[{"error": {...}}]`). T21's error parser handles both shapes.
4. **A free-tier quota of 0 isn't a rate limit to wait out.** The 429 carried "limit: 0" and a retry delay of about 14 hours. T22 caps any wait at 60 s (SPEC §5.5) and treats "limit: 0" as "model not on your plan": skip to the next model in the chain and say so in Settings.
5. **Fences happen.** Ollama with thinking off wrapped its JSON in a Markdown fence. T22's output pipeline strips fences before validating (already in SPEC §5.5).
6. **Local thinking is slow.** About 100 s and about 2,000 tokens per posting with thinking on, against about 10 s off, on this Mac. At about 40 analyses a day that's over an hour. **Decided with you (2026-10-19):** local models run with thinking off by default, relying on validation plus the one repair call. T22 gives local providers a 180 s timeout, against 60 s for cloud.
7. **Hidden thinking tokens.** Gemini Flash thinks by default without showing it: 504 tokens appear only in `total_tokens`, five times the visible answer. T21 counts output as `total − prompt` when that's larger than `completion_tokens`, so budgets and costs aren't understated. Flash-Lite showed none.
8. **503 is temporary; 501 isn't.** A busy Gemini model answers 503 "high demand" in the same array wrapper. That's the 5xx the client retries with backoff, unlike Ollama's 501.
9. **Temperature 0 isn't fully deterministic.** The same model gave different lists on two runs (a manual run and the harness run), though the harness run then repeated exactly. That supports caching by input hash (SPEC §5.5) and means prompt evals should repeat each posting.
10. **Prompt rules for T28 (`analyzeJob`):**
   - one requirement per item, never several skills in one;
   - never a job title as a requirement;
   - no booleans for many-valued facts. Gemini answered `remote: true` in one mode and `false` in the other for "hybrid, 2 days a week"; the real schema uses the remote-scope enum.

## Privacy and secrets

- **No keys in the fixtures.** The key came from `GEMINI_API_KEY` in your own terminal and is in no fixture. `RecordedRepliesTests` fails if anything shaped like a Google key appears there.
- **Thought signatures redacted.** Gemini's opaque `thought_signature` blobs are replaced with "redacted" when saved.
- **No personal data.** The sample posting is fictional and nothing personal was sent.
