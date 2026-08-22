#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
DERIVED="$ROOT/.release-build"
DIST="$ROOT/dist"
STAGE="$DIST/dmg-root"
APP="$STAGE/M4 Companion.app"
PROJECT="$ROOT/MomentumDeviceSwitcher.xcodeproj"

command -v xcodegen >/dev/null || {
  echo "xcodegen is required (brew install xcodegen)." >&2
  exit 1
}

[[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]] || {
  echo "BUILD_NUMBER must be a non-negative integer." >&2
  exit 1
}

cd "$ROOT"
xcodegen generate
xcodebuild \
  -project "$PROJECT" \
  -scheme MomentumDeviceSwitcher \
  -configuration Release \
  -derivedDataPath "$DERIVED" \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  CODE_SIGNING_ALLOWED=NO \
  clean build

rm -rf "$DIST"
mkdir -p "$STAGE"
ditto "$DERIVED/Build/Products/Release/M4 Companion.app" "$APP"
rm -f \
  "$APP/Contents/embedded.provisionprofile" \
  "$APP/Contents/PlugIns/MomentumDeviceWidget.appex/Contents/embedded.provisionprofile"

for framework in "$APP"/Contents/Frameworks/*.framework; do
  codesign --force --sign - "$framework"
done
codesign --force --sign - \
  --entitlements "$ROOT/Distribution/Widget-AdHoc.entitlements" \
  "$APP/Contents/PlugIns/MomentumDeviceWidget.appex"
codesign --force --sign - \
  --entitlements "$ROOT/Distribution/Host-AdHoc.entitlements" \
  "$APP"

codesign --verify --deep --strict --verbose=4 "$APP"
ln -s /Applications "$STAGE/Applications"

DMG="$DIST/M4-Companion-${VERSION}-Technical-Preview.dmg"
hdiutil create \
  -volname "M4 Companion" \
  -srcfolder "$STAGE" \
  -ov \
  -format UDZO \
  "$DMG"

shasum -a 256 "$DMG" | tee "$DIST/SHA256SUMS.txt"
echo "Created: $DMG"
