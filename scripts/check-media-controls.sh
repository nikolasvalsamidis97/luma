#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --product Luma
CHECK_DIR="$(mktemp -d /tmp/luma-media-checks.XXXXXX)"
APP="$CHECK_DIR/Luma Media Checks.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks"
FRAMEWORK='Vendor/VLCKit - binary package/VLCKit.xcframework/macos-arm64_x86_64'
ditto --norsrc --noextattr "$FRAMEWORK/VLCKit.framework" "$APP/Contents/Frameworks/VLCKit.framework"
cp scripts/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.luma.media-checks' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName Luma Media Checks' "$APP/Contents/Info.plist"
swiftc -parse-as-library -target "$(uname -m)-apple-macos14.0" -I .build/debug/Modules -F "$FRAMEWORK" -framework VLCKit \
  Sources/StreamApp/Theme.swift Sources/StreamApp/Player.swift Sources/StreamApp/PlayerPresentation.swift Sources/StreamApp/SubtitleControls.swift Sources/StreamApp/PlaybackControls.swift Sources/StreamApp/MediaFactsStore.swift scripts/check-media-controls.swift \
  .build/debug/StreamCore.build/*.swift.o -o "$APP/Contents/MacOS/Luma"
codesign --force --deep --sign - "$APP"
echo "Media controls check app: $APP"
"$APP/Contents/MacOS/Luma" "${1:-}"
