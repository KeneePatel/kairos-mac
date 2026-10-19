#!/usr/bin/env bash
# No hard-coded colours (CONSTRAINTS.md, "Design tokens"): views take every
# colour from the Asset Catalog (generated from design/kairos/tokens.json),
# and the web app from its generated tokens stylesheet.
# Exit 0 clean, 1 violation.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

fail=0
if [ -d App ]; then
    hits=$(grep -rnE '#[0-9A-Fa-f]{6}\b|Color\(\s*red:|Color\(\s*\.sRGB|Color\(\s*hex|NSColor\(\s*(calibrated|device|srgb|red)|UIColor\(' \
        --include='*.swift' App || true)
    if [ -n "$hits" ]; then
        echo "check-design: hard-coded colours in App/ (use Color(.tokenName) instead):"
        echo "$hits"
        fail=1
    fi
fi
if [ -d Web ]; then
    hits=$(grep -rnE '#[0-9A-Fa-f]{3,8}\b|rgba?\(' --include='*.css' --include='*.js' --include='*.html' Web \
        | grep -v 'Web/tokens.css' || true)
    if [ -n "$hits" ]; then
        echo "check-design: hard-coded colours in Web/ (use the custom properties in Web/tokens.css):"
        echo "$hits"
        fail=1
    fi
fi

[ "$fail" -eq 0 ] && echo "check-design: clean"
exit "$fail"
