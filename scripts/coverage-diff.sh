#!/usr/bin/env bash
# Changed-line coverage for the core modules (CONSTRAINTS.md, "Coverage").
# Reads the coverage the test run already wrote, so run this first:
#   swift test --package-path Packages/KairosCore --enable-code-coverage
#
# Usage: scripts/coverage-diff.sh [base-ref]
#   base-ref defaults to origin/main, or HEAD before a remote exists.
# Exit 0 at or above the threshold (or nothing to measure), 1 below, 2 could not run.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

pkg=Packages/KairosCore
threshold=80
modules="Store Resume AI Screening Tailoring Engine"
base="${1:-}"
if [ -z "$base" ]; then
    if git rev-parse -q --verify origin/main >/dev/null; then base=origin/main; else base=HEAD; fi
fi

bin=$(swift build --package-path "$pkg" --show-bin-path)
profdata="$bin/codecov/default.profdata"
# Newer toolchains build one bundle per test target; older ones a single
# KairosCorePackageTests bundle. Take every test binary found.
objects=()
for exe in "$bin"/*.xctest/Contents/MacOS/*; do
    [ -f "$exe" ] || continue
    if [ ${#objects[@]} -eq 0 ]; then objects+=("$exe"); else objects+=(-object "$exe"); fi
done
if [ ! -f "$profdata" ] || [ ${#objects[@]} -eq 0 ]; then
    echo "coverage-diff: no coverage data; run swift test --enable-code-coverage first"
    exit 2
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
xcrun llvm-cov export -format=lcov -instr-profile "$profdata" "${objects[@]}" >"$work/lcov"

# Changed lines as "absolute-path:line", from tracked diffs and untracked files.
root=$(pwd)
: >"$work/changed"
for m in $modules; do
    dir="$pkg/Sources/$m"
    [ -d "$dir" ] || continue
    git diff -U0 "$base" -- "$dir" | awk -v root="$root" '
        /^\+\+\+ / { file = substr($2, 3); next }
        /^@@/ {
            split($3, a, ","); start = substr(a[1], 2); count = (a[2] == "") ? 1 : a[2]
            for (i = 0; i < count; i++) print root "/" file ":" (start + i)
        }' >>"$work/changed"
    git ls-files --others --exclude-standard -- "$dir" | while read -r f; do
        awk -v p="$root/$f" '{ print p ":" NR }' "$f" >>"$work/changed"
    done
done

# Join with lcov line records (DA:line,count under SF:path).
awk -v threshold="$threshold" '
    FNR == NR { want[$0] = 1; next }
    /^SF:/ { sf = substr($0, 4); next }
    /^DA:/ {
        split(substr($0, 4), d, ","); key = sf ":" d[1]
        if (key in want) { total++; if (d[2] > 0) covered++; else missed[key] = 1 }
    }
    END {
        if (total == 0) { print "coverage-diff: no changed lines to measure"; exit 0 }
        pct = covered * 100 / total
        printf "coverage-diff: %d of %d changed lines covered (%.1f%%, need %d%%)\n", covered, total, pct, threshold
        if (pct < threshold) { for (k in missed) print "  not covered: " k; exit 1 }
    }' "$work/changed" "$work/lcov"
