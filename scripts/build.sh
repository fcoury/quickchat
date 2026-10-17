#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-release}"
./scripts/swift.sh build -c "$configuration"
bin_path="$(./scripts/swift.sh build -c "$configuration" --show-bin-path)"
bundle="dist/QuickChat.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp "$bin_path/QuickChat" "$bundle/Contents/MacOS/QuickChat.next"
mv "$bundle/Contents/MacOS/QuickChat.next" "$bundle/Contents/MacOS/QuickChat"
cp Resources/Info.plist "$bundle/Contents/Info.plist"
cp Resources/QuickChat.icns "$bundle/Contents/Resources/QuickChat.icns"
# Compile the native icon so Tahoe uses its charcoal canvas instead of placing
# the legacy padded artwork on a system-provided light tile.
icon_build="$PWD/.build/icon-assets"
mkdir -p "$icon_build"
xcrun actool Resources/QuickChat.icon --compile "$icon_build" \
    --platform macosx --minimum-deployment-target 14.0 --app-icon QuickChat \
    --output-partial-info-plist "$icon_build/Info.plist"
cp "$icon_build/Assets.car" "$bundle/Contents/Resources/Assets.car"
codesign --force --sign - --identifier dev.fcoury.QuickChat "$bundle"
printf 'Built %s/%s\n' "$PWD" "$bundle"
