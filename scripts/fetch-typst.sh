#!/usr/bin/env bash
# Downloads the pinned Typst release into Vendor/typst/ and verifies its
# SHA-256 (the digest GitHub publishes for the release asset). Typst is the
# only bundled binary (CONSTRAINTS.md, "Dependencies").
# Exit 0 when Vendor/typst/typst matches the pin, 1 otherwise.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

version="0.15.1"
asset="typst-aarch64-apple-darwin.tar.xz"
sha256="48f62ed034aa3a7978309579ac6ca00045e2ef0da73114e8af27cfd8e74dc05a"
url="https://github.com/typst/typst/releases/download/v${version}/${asset}"

dest=Vendor/typst
if [ -x "$dest/typst" ] && "$dest/typst" --version 2>/dev/null | grep -q "typst ${version}"; then
    echo "fetch-typst: typst ${version} already in ${dest}"
    exit 0
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
curl -fsSL "$url" -o "$work/$asset"
actual=$(shasum -a 256 "$work/$asset" | awk '{print $1}')
if [ "$actual" != "$sha256" ]; then
    echo "fetch-typst: checksum mismatch for $asset (expected $sha256, got $actual)"
    exit 1
fi
tar -xJf "$work/$asset" -C "$work"
mkdir -p "$dest"
cp "$work/typst-aarch64-apple-darwin/typst" "$dest/typst"
chmod +x "$dest/typst"
echo "fetch-typst: $("$dest/typst" --version) in ${dest}"
