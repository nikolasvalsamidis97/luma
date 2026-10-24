#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --product Luma
CHECK_DIR="$(mktemp -d /tmp/luma-episode-checks.XXXXXX)"
APP="$CHECK_DIR/Luma Episode Checks.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks"
FRAMEWORK='Vendor/VLCKit - binary package/VLCKit.xcframework/macos-arm64_x86_64'
ditto --norsrc --noextattr "$FRAMEWORK/VLCKit.framework" "$APP/Contents/Frameworks/VLCKit.framework"
cp scripts/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.luma.episode-checks' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName Luma Episode Checks' "$APP/Contents/Info.plist"
swiftc -parse-as-library -target "$(uname -m)-apple-macos14.0" -I .build/debug/Modules -F "$FRAMEWORK" -framework VLCKit \
  Sources/StreamApp/Theme.swift Sources/StreamApp/Player.swift Sources/StreamApp/PlayerPresentation.swift Sources/StreamApp/SubtitleControls.swift Sources/StreamApp/PlaybackControls.swift Sources/StreamApp/MediaFactsStore.swift Sources/StreamApp/MediaCard.swift Sources/StreamApp/DetailView.swift Sources/StreamApp/LibraryStore.swift scripts/check-episode-player.swift \
  .build/debug/StreamCore.build/*.swift.o -o "$APP/Contents/MacOS/Luma"
codesign --force --deep --sign - "$APP"
swift scripts/make-test-video.swift "$CHECK_DIR/video.mp4"
echo "Episode check app: $APP"
"$APP/Contents/MacOS/Luma" "$CHECK_DIR/video.mp4" "${1:-}"
