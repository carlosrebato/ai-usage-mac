#!/bin/sh

set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
DERIVED_DATA="$ROOT/.derivedData"
APP_PATH="$DERIVED_DATA/Build/Products/Release/AI Usage.app"
ARTIFACTS="$ROOT/.artifacts"
ZIP_PATH="$ARTIFACTS/AI-Usage-unsigned.zip"

cd "$ROOT"
xcodegen generate
xcodebuild \
  -quiet \
  -project AIUsage.xcodeproj \
  -scheme AIUsageMac \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  build

"$ROOT/Scripts/validate-bundle.sh" "$APP_PATH"

mkdir -p "$ARTIFACTS"
rm -f "$ZIP_PATH"
ditto -c -k --norsrc --keepParent "$APP_PATH" "$ZIP_PATH"
if zipinfo -1 "$ZIP_PATH" | grep -Eq '(^__MACOSX/|/\._|^\._)'; then
  echo "Artifact contains AppleDouble metadata." >&2
  exit 1
fi

echo "Unsigned diagnostic artifact: $ZIP_PATH"
