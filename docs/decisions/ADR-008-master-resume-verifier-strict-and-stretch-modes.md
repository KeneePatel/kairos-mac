# ADR-008: Master resume, verifier, strict and stretch modes

## Status
Accepted 2026-10-19, with the approved spec.

## Date
2026-10-19

## Context
You want the option to stretch beyond the master resume. Friends sharing the app may not.

## Decision
Strict by default for every account. Stretch is opt-in per user and off until they turn it on. Gap bullets are limited to skills marked Can discuss, every gap bullet is flagged, and the hard limits never bend.

## Alternatives considered
Always strict (rejected by you). Always stretch with free invention, like the original (no hard limits, nothing flagged, risky for friends who didn't choose it).

## Consequences
The verifier is the single enforcement point, so its tests are the most important in the codebase.
