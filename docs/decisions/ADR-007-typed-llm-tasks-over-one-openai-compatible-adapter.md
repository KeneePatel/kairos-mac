# ADR-007: Typed LLM tasks over one OpenAI-compatible adapter

## Status
Accepted 2026-10-19, with the approved spec.

## Date
2026-10-19

## Context
The preference or inherited choice this settles is cross-checked in SPEC.md §2; the requirement it serves is in the SPEC section named in the decision.

## Decision
- Each LLM use is a typed task: prompt builder, output schema, semantic check, version.
- A router picks the provider and model per task.
- One Chat Completions adapter covers Gemini (default), Ollama (fallback), Groq, OpenRouter and OpenAI. Foundation Models handles triage; Anthropic is optional.
- Every output is validated locally whatever the provider promises. Keys are per user and never synced.

## Alternatives considered
Provider SDKs (dependencies, a different shape each); free-text prompting with regex parsing, like the original (fragile); local MLX models (a dependency, multi-GB downloads).

## Consequences
Adding a provider is a preset, not code. Structured-output support varies, hence the capability flags and the mandatory local schema check.
