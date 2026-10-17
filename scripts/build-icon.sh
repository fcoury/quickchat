#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
icon_dir="$(mktemp -d "${TMPDIR:-/tmp}/quickchat-icon.XXXXXX")/QuickChat.iconset"
mkdir -p "$icon_dir"
trap 'rmdir "${icon_dir%/*}" 2>/dev/null || true' EXIT
swift scripts/prepare-icon.swift assets/quickchat-icon-concept.png "$icon_dir/normalized.png"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$icon_dir/normalized.png" --out "$icon_dir/icon_${size}x${size}.png" >/dev/null
    sips -z "$((size * 2))" "$((size * 2))" "$icon_dir/normalized.png" --out "$icon_dir/icon_${size}x${size}@2x.png" >/dev/null
done
rm "$icon_dir/normalized.png"
iconutil -c icns "$icon_dir" -o Resources/QuickChat.icns
# Remove only the generated renditions; keep the source artwork.
for size in 16 32 128 256 512; do
    rm "$icon_dir/icon_${size}x${size}.png" "$icon_dir/icon_${size}x${size}@2x.png"
done
rmdir "$icon_dir"
