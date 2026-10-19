# ADR-001: Native SwiftUI app

## Status
Accepted 2026-10-18. The owner chose SwiftUI over Tauri 2 (comparison in `docs/platform-choice.md`).

## Date
2026-10-19

## Context
The preference or inherited choice this settles is cross-checked in SPEC.md §2; the requirement it serves is in the SPEC section named in the decision.

## Decision
SwiftUI app with the core in a Swift package.

## Alternatives considered
Tauri 2 (best if Windows comes); Electron + Python (today: three runtimes, ~400 MB); Python + pywebview.

## Consequences
No Windows worker without a port. The backend and the PWA are already platform-neutral.
