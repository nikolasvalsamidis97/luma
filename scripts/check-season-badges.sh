#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --product Luma
BADGE_DIR=$(mktemp -d /tmp/luma-badge-checks.XXXXXX)
APP="$BADGE_DIR/Luma Badge Checks.app"
mkdir -p "$APP/Contents/MacOS"
cp scripts/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.luma.badge-checks' "$APP/Contents/Info.plist"
swiftc -parse-as-library -target "$(uname -m)-apple-macos14.0" -I .build/debug/Modules \
  Sources/StreamApp/Theme.swift Sources/StreamApp/MediaCard.swift Sources/StreamApp/MediaFactsStore.swift scripts/check-season-badges.swift \
  .build/debug/StreamCore.build/*.swift.o -o "$APP/Contents/MacOS/Luma"
codesign --force --sign - "$APP"
echo "$APP"
"$APP/Contents/MacOS/Luma"
