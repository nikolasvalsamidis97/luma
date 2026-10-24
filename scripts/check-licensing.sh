#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --product Luma
CHECK_DIR=$(mktemp -d /tmp/luma-license-checks.XXXXXX)
APP="$CHECK_DIR/Luma Activation Checks.app"
mkdir -p "$APP/Contents/MacOS"
cp scripts/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.luma.activation-checks' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName Luma Activation Checks' "$APP/Contents/Info.plist"
swiftc -D DEBUG -parse-as-library -target arm64-apple-macos14.0 -I .build/debug/Modules Sources/StreamApp/Theme.swift Sources/StreamApp/LicenseStore.swift Sources/StreamApp/LicenseView.swift scripts/check-licensing.swift .build/debug/StreamCore.build/*.swift.o -o "$APP/Contents/MacOS/Luma"
codesign --force --sign - "$APP"
python3 scripts/fixture-licensing.py "$CHECK_DIR" &
FIXTURE_PID=$!
trap 'kill "$FIXTURE_PID" 2>/dev/null || true' EXIT
for i in {1..50}; do if [ -s "$CHECK_DIR/port" ]; then break; fi; sleep 0.1; done
echo "Activation check app: $APP"
"$APP/Contents/MacOS/Luma" "http://127.0.0.1:$(cat "$CHECK_DIR/port")" "$CHECK_DIR/key" "${1:-}"
