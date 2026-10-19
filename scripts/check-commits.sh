#!/usr/bin/env bash
# Every commit in the range carries no AI attribution, and is authored and
# committed by the owner (AGENTS.md, CONSTRAINTS.md "Commits").
#
# Usage: scripts/check-commits.sh [range] [--allow-other-authors]
#   range defaults to origin/main..HEAD, or all of HEAD before a remote exists.
#   --allow-other-authors is for pull requests from outside contributors: it
#   still rejects AI attribution but accepts any author.
# Exit 0 clean, 1 violation, 2 could not run.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

owner="Kenee Patel <patelkenee2804@gmail.com>"
range=""
others=0
for arg in "$@"; do
    case "$arg" in
        --allow-other-authors) others=1 ;;
        *) range="$arg" ;;
    esac
done
if [ -z "$range" ]; then
    if git rev-parse -q --verify origin/main >/dev/null; then range="origin/main..HEAD"; else range="HEAD"; fi
fi

shas=$(git rev-list "$range") || { echo "check-commits: can't read range $range"; exit 2; }

bad=0
for sha in $shas; do
    short=$(git rev-parse --short "$sha")
    author=$(git log -1 --format='%an <%ae>' "$sha")
    committer=$(git log -1 --format='%cn <%ce>' "$sha")
    if [ "$others" -eq 0 ] && { [ "$author" != "$owner" ] || [ "$committer" != "$owner" ]; }; then
        echo "check-commits: $short author '$author', committer '$committer' (expected $owner)"
        bad=1
    fi
    trailers=$(git log -1 --format='%(trailers:only,unfold)' "$sha" | tr -d '[:space:]')
    if [ -n "$trailers" ]; then
        echo "check-commits: $short has trailers: $(git log -1 --format='%(trailers:only,unfold)' "$sha" | tr '\n' ' ')"
        bad=1
    fi
    if git log -1 --format='%B' "$sha" | grep -qiE 'co-authored-by|generated with|🤖'; then
        echo "check-commits: $short message contains AI attribution"
        bad=1
    fi
done

[ "$bad" -eq 0 ] && echo "check-commits: clean ($range)"
exit "$bad"
