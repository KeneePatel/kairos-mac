# ADR-014: One master resume per user

## Status
Accepted 2026-10-19, with the approved spec.

## Date
2026-10-19

## Context
The builders need one complete, editable source of truth, and the verifier needs ids to check claims against.

## Decision
A structured master resume (contact, experience, projects, education, skills marked Proven or Can discuss, additional sections) with required LinkedIn URL, phone and email, versioned on every save. It replaces both the fact bank and per-role base resumes.

## Alternatives considered
Free-text resume files (the original; claims can't be checked); several base resumes per role (duplicate upkeep; rejected by you).

## Consequences
Onboarding has one real step, reviewing the imported draft. After that, every builder reads from one place.
