# ADR-002: System SQLite with a thin wrapper

## Status
Accepted 2026-10-19, with the approved spec.

## Date
2026-10-19

## Context
The preference or inherited choice this settles is cross-checked in SPEC.md §2; the requirement it serves is in the SPEC section named in the decision.

## Decision
`import SQLite3` plus about 400 lines of wrapper, with one database file per account.

## Alternatives considered
GRDB (the first dependency to take if needed); SwiftData / Core Data (opaque schema); SQLite.swift.

## Consequences
None recorded beyond the decision itself.
