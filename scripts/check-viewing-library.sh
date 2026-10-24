#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --product Luma
CHECK_DIR="$(mktemp -d /tmp/luma-viewing-checks.XXXXXX)"
APP="$CHECK_DIR/Luma Viewing Checks.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks"
FRAMEWORK='Vendor/VLCKit - binary package/VLCKit.xcframework/macos-arm64_x86_64'
ditto --norsrc --noextattr "$FRAMEWORK/VLCKit.framework" "$APP/Contents/Frameworks/VLCKit.framework"
cp scripts/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.luma.viewing-checks' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName Luma Viewing Checks' "$APP/Contents/Info.plist"
swiftc -parse-as-library -target "$(uname -m)-apple-macos14.0" -I .build/debug/Modules -F "$FRAMEWORK" -framework VLCKit \
  Sources/StreamApp/Theme.swift Sources/StreamApp/Player.swift Sources/StreamApp/PlayerPresentation.swift Sources/StreamApp/SubtitleControls.swift Sources/StreamApp/PlaybackControls.swift Sources/StreamApp/MediaFactsStore.swift Sources/StreamApp/MediaCard.swift Sources/StreamApp/DetailView.swift Sources/StreamApp/LibraryStore.swift Sources/StreamApp/LibraryView.swift Sources/StreamApp/ViewingShelves.swift scripts/check-viewing-library.swift \
  .build/debug/StreamCore.build/*.swift.o -o "$APP/Contents/MacOS/Luma"
codesign --force --deep --sign - "$APP"
swift scripts/make-test-video.swift "$CHECK_DIR/video.mp4"
python3 scripts/fixture-provider.py "$CHECK_DIR/video.mp4" 0 "$CHECK_DIR/port" > "$CHECK_DIR/provider.log" 2>&1 &
PROVIDER_PID=$!
trap 'kill "$PROVIDER_PID" 2>/dev/null || true' EXIT
for i in {1..50}; do if [ -s "$CHECK_DIR/port" ]; then break; fi; sleep 0.1; done
PORT=$(cat "$CHECK_DIR/port")
echo "Viewing check app: $APP"
"$APP/Contents/MacOS/Luma" "$CHECK_DIR/video.mp4" "http://127.0.0.1:$PORT" "${1:-}"
