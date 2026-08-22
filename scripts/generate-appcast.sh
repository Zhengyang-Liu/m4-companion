#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${VERSION:?Set VERSION to the release version, for example 0.1.1}"
ARCHIVE="${ARCHIVE:-$ROOT/dist/M4-Companion-${VERSION}-Technical-Preview.dmg}"
OUTPUT="${OUTPUT:-$ROOT/docs/appcast.xml}"
ACCOUNT="${SPARKLE_KEY_ACCOUNT:-com.zhengyangliu.MomentumDeviceSwitcher}"
DOWNLOAD_URL_PREFIX="${DOWNLOAD_URL_PREFIX:-https://github.com/Zhengyang-Liu/m4-companion/releases/download/v${VERSION}/}"
TOOLS="$ROOT/.release-build/SourcePackages/artifacts/sparkle/Sparkle/bin"
GENERATE_APPCAST="$TOOLS/generate_appcast"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/m4-appcast.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT

[[ -f "$ARCHIVE" ]] || {
  echo "Update archive not found: $ARCHIVE" >&2
  exit 1
}

if [[ ! -x "$GENERATE_APPCAST" ]]; then
  xcodegen generate
  xcodebuild \
    -resolvePackageDependencies \
    -project "$ROOT/MomentumDeviceSwitcher.xcodeproj" \
    -scheme MomentumDeviceSwitcher \
    -clonedSourcePackagesDirPath "$ROOT/.release-build/SourcePackages"
fi

cp "$ARCHIVE" "$STAGE/"
if [[ -f "$OUTPUT" ]]; then
  cp "$OUTPUT" "$STAGE/appcast.xml"
fi

"$GENERATE_APPCAST" \
  --account "$ACCOUNT" \
  --download-url-prefix "$DOWNLOAD_URL_PREFIX" \
  --link "https://zhengyang-liu.github.io/m4-companion/" \
  --maximum-versions 3 \
  --maximum-deltas 0 \
  -o "$STAGE/appcast.xml" \
  "$STAGE"

mkdir -p "$(dirname "$OUTPUT")"
cp "$STAGE/appcast.xml" "$OUTPUT"
xmllint --noout "$OUTPUT"
echo "Created signed appcast: $OUTPUT"
