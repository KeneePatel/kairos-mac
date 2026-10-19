# ADR-013: Distribution without the paid developer program

## Status
Accepted 2026-10-19, with the approved spec.

## Date
2026-10-19

## Context
The preference or inherited choice this settles is cross-checked in SPEC.md §2; the requirement it serves is in the SPEC section named in the decision.

## Decision
A DMG on GitHub Releases signed with one stable self-signed code-signing certificate; an in-app update check against the GitHub Releases API; an install guide covering "Open Anyway" in System Settings. A tag-triggered GitHub Actions workflow (free macOS runners for public repos) builds and publishes it, with the certificate stored as an encrypted repository secret.

## Alternatives considered
Notarized Developer ID (needs the paid program); Homebrew cask (unsigned casks are being phased out); build-from-source only.

## Consequences
None recorded beyond the decision itself.
