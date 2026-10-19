# Spike T20: structured output from Gemini and Ollama

**Date:** 2026-10-19 · **Harness:** `Packages/KairosCore/Tests/LLMTests/LiveStructuredOutputTests.swift` · **Replies:** `Packages/KairosCore/Tests/Fixtures/llm/` · **Offline checks:** `RecordedRepliesTests.swift`

**Question:** for each provider preset, does asking for JSON through `response_format` work, and do the replies pass our own schema check? The answer sets the capability flags T21's presets carry.

**Method:** one fictional sample posting (Northline Freight, design sample data), one small schema: requirements as `{text, kind: must|nice}`, `years_required`, and `remote`. Each reply was validated with `SchemaValidator` and scored against a hand labelling of the posting: 4 must-haves and 3 nice-to-haves.

## Results

| Preset · model | Mode | HTTP | Schema check | Requirements (precision / recall) | Output tokens | Time |
|---|---|---|---|---|---|---|
| Gemini · `gemini-flash-lite-latest` | `json_schema` (strict) | 200 | valid | 1.0 / 1.0 | 97 | under 1 s |
| Gemini · `gemini-flash-lite-latest` | `json_object` | 200 | valid | 1.0 / 1.0 | 208 (pretty-printed) | under 1 s |
| Gemini · `gemini-omni-1.1-flash` | both | 429 | — | — | — | — |
| Ollama 0.40 · `qwen3.5:4B` (nvfp4) | `json_schema` and `json_object` | **501** "structured output is unavailable" | — | — | — | instant |
| Ollama · `qwen3.5:4B` | no `response_format`, thinking on | 200 | valid | 1.0 / 1.0 on one run; 1.0 / 0.71 on another (merged three nice-to-haves into one item) | 1,904–2,669 | 92–117 s |
| Ollama · `qwen3.5:4B` | no `response_format`, thinking off (`reasoning_effort: none`) | 200 | valid after removing a code fence | 0.875 / 1.0 on one run (listed the job title as a requirement); 1.0 / 1.0 on another | 221–239 | 10–11 s |

**Gemini Flash (not Lite) is still unmeasured.** The first run's picker sorted model names and chose `gemini-omni-1.1-flash`, a variant whose free-tier quota is 0. The picker now prefers Google's `gemini-flash-latest` / `gemini-flash-lite-latest` aliases and never picks a variant. One more run with your key fills the row.

## Capability flags for T21

| Preset | Structured output | Notes |
|---|---|---|
| Gemini (OpenAI-compatible) | **schema** | Strict `json_schema` works. It also uses half the tokens of `json_object`, which pretty-prints. |
| Ollama local | **learned per model**, default **prompt-only** | Some builds refuse every `response_format` with HTTP 501. The adapter must resend without it and remember the model's answer. |
| Ollama Cloud, Groq, OpenRouter, OpenAI | unmeasured | Start as schema; same 501/400 downgrade path. |

## What this changes

1. **Capability is per model, not per preset.** Ollama's API accepts `response_format`, but this model build refuses it. T21 records a per-(provider, model) flag that starts at the preset default and drops to prompt-only on that refusal.
2. **HTTP 501 is not retried.** "structured output is unavailable" means resend once without `response_format`; retrying it as a 5xx (SPEC §5.5) can never succeed. T21 maps it; T22 doesn't retry it.
3. **Gemini errors arrive wrapped in an array** (`[{"error": {...}}]`). T21's error parser handles both shapes.
4. **A free-tier quota of 0 isn't a rate limit to wait out.** The 429 carried "limit: 0" and a retry delay of about 14 hours. T22 caps any wait at 60 s (SPEC §5.5) and treats "limit: 0" as "model not on your plan": skip to the next model in the chain and say so in Settings.
5. **Fences happen.** Ollama with thinking off wrapped its JSON in a Markdown fence. T22's output pipeline strips fences before validating (already in SPEC §5.5).
6. **Local thinking is slow.** About 100 s and about 2,000 tokens per posting with thinking on, against about 10 s off, on this Mac. At about 40 analyses a day that's over an hour. T22 gives local providers a longer timeout (proposed 180 s, against 60 s for cloud). Local extraction runs with thinking off by default, relying on validation plus the one repair call.
7. **Temperature 0 isn't deterministic.** The same model gave different lists on two runs. That supports caching by input hash (SPEC §5.5) and means prompt evals should repeat each posting.
8. **Prompt rules for T28 (`analyzeJob`):**
   - one requirement per item, never several skills in one;
   - never a job title as a requirement;
   - no booleans for many-valued facts. Gemini answered `remote: true` in one mode and `false` in the other for "hybrid, 2 days a week"; the real schema uses the remote-scope enum.

## Privacy and secrets

- **No keys in the fixtures.** The key came from `GEMINI_API_KEY` in your own terminal and is in no fixture. `RecordedRepliesTests` fails if anything shaped like a Google key appears there.
- **Thought signatures redacted.** Gemini's opaque `thought_signature` blobs are replaced with "redacted" when saved.
- **No personal data.** The sample posting is fictional and nothing personal was sent.
