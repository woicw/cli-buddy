#!/usr/bin/env bash
set -euo pipefail

# Generates Resources/AppIcon.icns from the 🐾 emoji.
#
# Pipeline:
#   1. gen-icon.swift renders 1024x1024 PNG on a dark rounded gradient
#   2. sips downsamples into every iconset size
#   3. iconutil packs the iconset into AppIcon.icns
#
# Run from project root:  bash scripts/gen-icon.sh

cd "$(dirname "$0")/.."

OUT_DIR="Resources"
ICONSET="$OUT_DIR/AppIcon.iconset"
ICNS="$OUT_DIR/AppIcon.icns"
MASTER="/tmp/cli-buddy-icon-1024.png"

mkdir -p "$ICONSET"

# 1. Render master PNG.
swift scripts/gen-icon.swift "$MASTER"

# 2. Every Apple-recognised iconset size/variant.
declare -a specs=(
    "icon_16x16.png:16"
    "icon_16x16@2x.png:32"
    "icon_32x32.png:32"
    "icon_32x32@2x.png:64"
    "icon_128x128.png:128"
    "icon_128x128@2x.png:256"
    "icon_256x256.png:256"
    "icon_256x256@2x.png:512"
    "icon_512x512.png:512"
    "icon_512x512@2x.png:1024"
)
for spec in "${specs[@]}"; do
    name="${spec%%:*}"
    px="${spec##*:}"
    sips -z "$px" "$px" "$MASTER" --out "$ICONSET/$name" > /dev/null
done

# 3. Pack into .icns.
iconutil -c icns "$ICONSET" -o "$ICNS"

# Leave the iconset on disk too — useful for debugging, ignored by git.
echo "wrote $ICNS"
du -h "$ICNS"
