#!/usr/bin/env bash
# Regenerates Resources/AppIcon.icns from Resources/AppIcon.svg (renders with Quick Look, scales with sips).
set -euo pipefail
cd "$(dirname "$0")/.."

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

qlmanage -t -s 1024 -o "$WORK" Resources/AppIcon.svg >/dev/null 2>&1
MASTER="$WORK/AppIcon.svg.png"
[[ -f "$MASTER" ]] || { echo "Quick Look did not render Resources/AppIcon.svg" >&2; exit 1; }

ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$MASTER" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) "$MASTER" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
echo "Wrote Resources/AppIcon.icns"
