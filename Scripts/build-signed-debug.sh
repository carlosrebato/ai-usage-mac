#!/bin/sh

set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
DERIVED_DATA="${AI_USAGE_DERIVED_DATA:-/private/tmp/AIUsageMacGroupDerivedData}"
: "${AI_USAGE_DEVELOPMENT_TEAM:?Set AI_USAGE_DEVELOPMENT_TEAM to your Apple team ID}"
DEVELOPMENT_TEAM="$AI_USAGE_DEVELOPMENT_TEAM"
APP_PATH="$DERIVED_DATA/Build/Products/Debug/AI Usage.app"
EXPECTED_BUNDLE_ID="${AI_USAGE_APP_BUNDLE_ID:-com.example.aiusage}"
EXPECTED_APP_GROUP="${AI_USAGE_APP_GROUP:-group.com.example.aiusage}"

cd "$ROOT"
xcodebuild \
  -quiet \
  -allowProvisioningUpdates \
  -project AIUsage.xcodeproj \
  -scheme AIUsageMac \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED_DATA" \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
  AI_USAGE_APP_BUNDLE_ID="$EXPECTED_BUNDLE_ID" \
  AI_USAGE_WIDGET_BUNDLE_ID="$EXPECTED_BUNDLE_ID.widgets" \
  AI_USAGE_APP_GROUP="$EXPECTED_APP_GROUP" \
  CODE_SIGN_STYLE=Automatic \
  build

codesign --verify --deep --strict --verbose=2 "$APP_PATH"

ACTUAL_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Contents/Info.plist")"
if [ "$ACTUAL_BUNDLE_ID" != "$EXPECTED_BUNDLE_ID" ]; then
  echo "Unexpected bundle identifier: $ACTUAL_BUNDLE_ID" >&2
  exit 1
fi

ACTUAL_TEAM="$(codesign -dvv "$APP_PATH" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
if [ "$ACTUAL_TEAM" != "$DEVELOPMENT_TEAM" ]; then
  echo "Unexpected signing team: $ACTUAL_TEAM" >&2
  exit 1
fi

APP_ENTITLEMENTS="$(codesign -d --entitlements - --xml "$APP_PATH" 2>/dev/null)"
WIDGET_PATH="$APP_PATH/Contents/PlugIns/AI Usage Widgets.appex"
WIDGET_ENTITLEMENTS="$(codesign -d --entitlements - --xml "$WIDGET_PATH" 2>/dev/null)"
NORMALIZED_APP_ENTITLEMENTS="$(printf '%s' "$APP_ENTITLEMENTS" | tr -d '[:space:]')"
if ! printf '%s' "$NORMALIZED_APP_ENTITLEMENTS" | grep -Fq '<key>com.apple.security.app-sandbox</key><true/>'; then
  echo "App is missing the sandbox entitlement required for persistent App Group access." >&2
  exit 1
fi
if ! printf '%s' "$APP_ENTITLEMENTS" | grep -Fq "<string>$EXPECTED_APP_GROUP</string>"; then
  echo "App is missing the expected App Group entitlement: $EXPECTED_APP_GROUP" >&2
  exit 1
fi
if ! printf '%s' "$WIDGET_ENTITLEMENTS" | grep -Fq "<string>$EXPECTED_APP_GROUP</string>"; then
  echo "Widget is missing the expected App Group entitlement: $EXPECTED_APP_GROUP" >&2
  exit 1
fi

echo "Signed development app: $APP_PATH"
echo "Bundle identifier: $ACTUAL_BUNDLE_ID"
echo "Team identifier: $ACTUAL_TEAM"
echo "App Group: $EXPECTED_APP_GROUP"
