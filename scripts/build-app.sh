#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
LICENSED=false
INSTALL=false
for option in "$@"; do
  case "$option" in
    --licensed) LICENSED=true ;;
    --install) INSTALL=true ;;
    *) echo "Unknown option: $option" >&2; exit 2 ;;
  esac
done
if $LICENSED; then
  python3 - <<'PYCONFIG'
import os, urllib.parse
u=urllib.parse.urlsplit(os.environ.get('LUMA_LICENSE_SERVER_URL',''))
if u.scheme != 'https' or not u.hostname or u.username or u.password or u.query or u.fragment:
    raise SystemExit('Set LUMA_LICENSE_SERVER_URL to your deployed HTTPS licensing service before making a licensed build.')
PYCONFIG
fi
FRAMEWORK_ROOT='Vendor/VLCKit - binary package'
ARCHIVE_SHA='45fc6398c80d1f8dc0e384a9c80704848e9e82a3a382611bf531fa83c198c276'
if [ ! -d "$FRAMEWORK_ROOT/VLCKit.xcframework" ]; then
  mkdir -p Vendor
  curl -fL --retry 3 'https://download.videolan.org/pub/cocoapods/prod/VLCKit-3.7.2-3e42ae47-79128878.tar.xz' -o Vendor/VLCKit.tar.xz
  printf '%s  %s\n' "$ARCHIVE_SHA" 'Vendor/VLCKit.tar.xz' | shasum -a 256 -c -
  tar -xf Vendor/VLCKit.tar.xz -C Vendor
fi
swift build -c release --product Luma
BIN_DIR="$(swift build -c release --show-bin-path)"
# Stage outside synced Documents folders: file providers can re-add FinderInfo during signing.
STAGING="$(mktemp -d /tmp/luma-build.XXXXXX)"
trap 'rm -rf "$STAGING"' EXIT
APP="$STAGING/Luma.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp "$BIN_DIR/Luma" "$APP/Contents/MacOS/Luma"
# A real framework copy (including its symlinks and playback plug-ins), never a link to a developer machine.
ditto --norsrc --noextattr "$FRAMEWORK_ROOT/VLCKit.xcframework/macos-arm64_x86_64/VLCKit.framework" "$APP/Contents/Frameworks/VLCKit.framework"
cp "$FRAMEWORK_ROOT/COPYING.txt" "$APP/Contents/Resources/VLCKit-COPYING.txt"
cp THIRD_PARTY_NOTICES.txt "$APP/Contents/Resources/THIRD_PARTY_NOTICES.txt"
cp scripts/Info.plist "$APP/Contents/Info.plist"
if $LICENSED; then
  LUMA_BUILD_PLIST="$APP/Contents/Info.plist" python3 - <<'PYPLIST'
import os, plistlib
path=os.environ['LUMA_BUILD_PLIST']
with open(path,'rb') as f: info=plistlib.load(f)
info.update(LumaLicensingEnabled=True,LumaLicenseServerURL=os.environ['LUMA_LICENSE_SERVER_URL'],CFBundleShortVersionString='0.8.0',CFBundleVersion='10')
with open(path,'wb') as f: plistlib.dump(info,f)
PYPLIST
fi
if [ -f assets/Luma.icns ]; then cp assets/Luma.icns "$APP/Contents/Resources/Luma.icns"; fi
# Local ad-hoc signature. Public distribution requires Developer ID signing and notarization.
xattr -cr "$APP"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
mkdir -p dist
ARCHIVE=dist/Luma.zip
if $LICENSED; then ARCHIVE=dist/Luma-licensed.zip; fi
ditto --norsrc --noextattr -c -k --keepParent "$APP" "$ARCHIVE"
if $INSTALL; then
  mkdir -p "$HOME/Applications"
  ditto --norsrc --noextattr "$APP" "$HOME/Applications/Luma.app"
  codesign --verify --deep --strict "$HOME/Applications/Luma.app"
  echo "Installed: $HOME/Applications/Luma.app"
fi
echo "Built self-contained app archive: $PWD/$ARCHIVE"
