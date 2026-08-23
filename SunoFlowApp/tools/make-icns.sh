#!/usr/bin/env bash
# Regenerates Resources/AppIcon.icns from the brand mark.
#
# tools/make-icon.swift draws one PNG at a given pixel size; this renders the
# whole iconset at native resolution (rather than downsampling a single 1024px
# master, which smears the mark's thin strokes at 16pt) and hands it to
# iconutil. The mark comes from Sources/SunoFlow/BrandMark.swift — the same SVG
# paths the website ships.
#
# Usage: tools/make-icns.sh
set -euo pipefail

cd "$(dirname "$0")/.."

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# swiftc only accepts top-level statements in a file called main.swift, so the
# generator is copied under that name to be compiled with the mark.
cp tools/make-icon.swift "$WORK/main.swift"
cp Sources/SunoFlow/BrandMark.swift "$WORK/BrandMark.swift"
swiftc -O -o "$WORK/make-icon" "$WORK/main.swift" "$WORK/BrandMark.swift"

ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"

# The sizes iconutil expects, as "<pixels> <filename>".
while read -r px name; do
    "$WORK/make-icon" "$ICONSET/$name" "$px" >/dev/null
done <<'SIZES'
16 icon_16x16.png
32 icon_16x16@2x.png
32 icon_32x32.png
64 icon_32x32@2x.png
128 icon_128x128.png
256 icon_128x128@2x.png
256 icon_256x256.png
512 icon_256x256@2x.png
512 icon_512x512.png
1024 icon_512x512@2x.png
SIZES

iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
echo "wrote Resources/AppIcon.icns"
