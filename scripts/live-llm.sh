#!/usr/bin/env bash
# Runs the opt-in live LLM tests with your Gemini key from the macOS Keychain. The key goes
# straight into the test process's environment; this script never prints it.
#
# Store a key once (you're prompted for it; nothing is echoed or kept in shell history). A
# separate key just for testing is best, so it can be revoked on its own:
#   security add-generic-password -s com.keneepatel.kairos.dev -a gemini -w
# Remove it:
#   security delete-generic-password -s com.keneepatel.kairos.dev -a gemini
#
# Usage: scripts/live-llm.sh [test filter]     (default: LiveAdapter)
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

filter="${1:-LiveAdapter}"
if ! key=$(security find-generic-password -s com.keneepatel.kairos.dev -a gemini -w 2>/dev/null) || [ -z "$key" ]; then
    echo "live-llm: no Gemini key in the Keychain. Add one with:" >&2
    echo "  security add-generic-password -s com.keneepatel.kairos.dev -a gemini -w" >&2
    exit 2
fi
KAIROS_LIVE_LLM=1 GEMINI_API_KEY="$key" exec swift test --package-path Packages/KairosCore --filter "$filter"
