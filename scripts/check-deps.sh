#!/usr/bin/env bash
# Fails if what ships would depend on anything beyond Apple's SDK and the
# typst binary (CONSTRAINTS.md, "Dependencies"). Exit 0 clean, 1 violation.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

fail=0
report() { echo "check-deps: $1"; fail=1; }

# Swift packages: the core package resolves nothing.
deps=$(swift package --package-path Packages/KairosCore show-dependencies 2>&1)
if ! grep -q "No external dependencies found" <<<"$deps"; then
    report "Packages/KairosCore resolves Swift packages:"
    echo "$deps"
fi

# The app project adds none either.
if [ -f App/project.yml ] && grep -qE '^packages:' App/project.yml; then
    report "App/project.yml declares Swift packages"
fi

# Bundled binaries: only typst.
if [ -d Vendor ]; then
    for entry in Vendor/*; do
        [ -e "$entry" ] || continue
        [ "$(basename "$entry")" = "typst" ] || report "unlisted bundled binary: $entry"
    done
fi

# The phone web app has no npm packages.
if [ -e Web/package.json ] || [ -d Web/node_modules ]; then
    report "Web/ has npm packages"
fi

[ "$fail" -eq 0 ] && echo "check-deps: clean"
exit "$fail"
