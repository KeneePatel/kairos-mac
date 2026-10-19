# ADR-011: Generic remote row store

## Status
Accepted 2026-10-19, with the approved spec.

## Date
2026-10-19

## Context
The preference or inherited choice this settles is cross-checked in SPEC.md §2; the requirement it serves is in the SPEC section named in the decision.

## Decision
One `sync_row` table (user, table, row id, HLC, tombstone, JSONB data, seq). Clients may only read it; writes go through `sync_push`, which serializes each user's pushes with an advisory lock.

## Alternatives considered
A mirrored per-table Postgres schema (two dialects); direct PostgREST upserts (no conditional last-writer-wins, unsafe pull ordering).

## Consequences
No server-side queries over individual fields. Not needed: all logic runs on clients.
