# ADR-010: Accounts: Supabase Auth, invite-only

## Status
Accepted 2026-10-19, with the approved spec.

## Date
2026-10-19

## Context
The preference or inherited choice this settles is cross-checked in SPEC.md §2; the requirement it serves is in the SPEC section named in the decision.

## Decision
Email + password with confirmation, Google and GitHub OAuth through `ASWebAuthenticationSession` with PKCE, and invites enforced by a before-user-created hook. Sessions live in the Keychain. Deletion via a security-definer function after Storage cleanup.

## Alternatives considered
Open sign-up (abuse and quota risk); magic links only (more email volume on a constrained SMTP); supabase-swift SDK (a dependency); writing our own auth (never).

## Consequences
None recorded beyond the decision itself.
