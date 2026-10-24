#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --product Luma
CHECK_DIR="$(mktemp -d /tmp/luma-subtitle-checks.XXXXXX)"
APP="$CHECK_DIR/Luma Subtitle Checks.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks"
FRAMEWORK='Vendor/VLCKit - binary package/VLCKit.xcframework/macos-arm64_x86_64'
ditto --norsrc --noextattr "$FRAMEWORK/VLCKit.framework" "$APP/Contents/Frameworks/VLCKit.framework"
cp scripts/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.luma.subtitle-checks' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName Luma Subtitle Checks' "$APP/Contents/Info.plist"
swiftc -parse-as-library -target "$(uname -m)-apple-macos14.0" -I .build/debug/Modules -F "$FRAMEWORK" -framework VLCKit \
  Sources/StreamApp/Theme.swift Sources/StreamApp/Player.swift Sources/StreamApp/PlayerPresentation.swift Sources/StreamApp/SubtitleControls.swift Sources/StreamApp/PlaybackControls.swift Sources/StreamApp/MediaFactsStore.swift scripts/check-subtitles.swift \
  .build/debug/StreamCore.build/*.swift.o -o "$APP/Contents/MacOS/Luma"
codesign --force --deep --sign - "$APP"
printf '1\n00:00:00,000 --> 00:02:00,000\nA better seat for every story.\n' > "$CHECK_DIR/sample.srt"
# The local 10-second silent H.264 fixture is sufficient; no provider or account is used.
swift scripts/make-test-video.swift "$CHECK_DIR/video.mp4"
echo "Subtitle check app: $APP"
"$APP/Contents/MacOS/Luma" "$CHECK_DIR/video.mp4" "$CHECK_DIR/sample.srt" "${1:-}"
