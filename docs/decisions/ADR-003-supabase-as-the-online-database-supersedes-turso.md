# ADR-003: Supabase as the online database (supersedes "Turso")

## Status
Accepted 2026-10-19, with the approved spec.

## Date
2026-10-19

## Context
Friends need sign-up and sign-in, and each user's data must be invisible to the others, on free tiers, with minimal client dependencies.

## Decision
Supabase Free: Auth + Postgres with row-level security + Storage, all over REST, in the Canada (Central) region.

## Alternatives considered
- *Turso:* same dialect as SQLite, but no end-user auth. It would need Clerk or Auth0 (JWKS, beta) plus per-user databases created through its Platform API by a backend.
- *Cloudflare D1 + Worker:* auth written by hand.
- *Neon:* Auth and a Data API in beta; no file storage; 0.5 GB.
- *Firebase:* Storage has required a billing account since February 2026; NoSQL; heavy SDK if not using REST.
- *CloudKit:* needs the paid developer program.
- *PocketBase:* a server to host.

## Consequences
Postgres on the server, SQLite on clients, bridged by a generic row store (ADR-011). A free project pauses after a week of no activity.
