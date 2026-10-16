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
codesign --force --sign - --identifier dev.fcoury.QuickChat "$bundle"
printf 'Built %s/%s\n' "$PWD" "$bundle"
