#!/bin/sh

set -eu

APP_PATH="${1:-.derivedData/Build/Products/Release/AI Usage.app}"
EXPECTED_APP_ID="${AI_USAGE_APP_BUNDLE_ID:-com.example.aiusage}"
EXPECTED_WIDGET_ID="${AI_USAGE_WIDGET_BUNDLE_ID:-$EXPECTED_APP_ID.widgets}"

fail() {
  echo "Bundle validation failed: $1" >&2
  exit 1
}

[ -d "$APP_PATH" ] || fail "app not found at $APP_PATH"

APP_INFO="$APP_PATH/Contents/Info.plist"
APP_EXECUTABLE="$APP_PATH/Contents/MacOS/AI Usage"
PLUGINS_PATH="$APP_PATH/Contents/PlugIns"

[ -f "$APP_INFO" ] || fail "app Info.plist is missing"
[ -x "$APP_EXECUTABLE" ] || fail "app executable is missing"
[ -d "$PLUGINS_PATH" ] || fail "PlugIns directory is missing"

WIDGET_PATH="$(find "$PLUGINS_PATH" -maxdepth 1 -type d -name '*.appex' -print -quit)"
[ -n "$WIDGET_PATH" ] || fail "WidgetKit extension is missing"

WIDGET_INFO="$WIDGET_PATH/Contents/Info.plist"
[ -f "$WIDGET_INFO" ] || fail "widget Info.plist is missing"

read_plist() {
  /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null
}

APP_ID="$(read_plist "$APP_INFO" CFBundleIdentifier)"
WIDGET_ID="$(read_plist "$WIDGET_INFO" CFBundleIdentifier)"
APP_VERSION="$(read_plist "$APP_INFO" CFBundleShortVersionString)"
WIDGET_VERSION="$(read_plist "$WIDGET_INFO" CFBundleShortVersionString)"
APP_BUILD="$(read_plist "$APP_INFO" CFBundleVersion)"
WIDGET_BUILD="$(read_plist "$WIDGET_INFO" CFBundleVersion)"
EXTENSION_POINT="$(read_plist "$WIDGET_INFO" NSExtension:NSExtensionPointIdentifier)"

[ "$APP_ID" = "$EXPECTED_APP_ID" ] || fail "unexpected app bundle identifier: $APP_ID"
[ "$WIDGET_ID" = "$EXPECTED_WIDGET_ID" ] || fail "unexpected widget bundle identifier: $WIDGET_ID"
[ "$APP_VERSION" = "$WIDGET_VERSION" ] || fail "app and widget marketing versions differ"
[ "$APP_BUILD" = "$WIDGET_BUILD" ] || fail "app and widget build numbers differ"
[ "$EXTENSION_POINT" = "com.apple.widgetkit-extension" ] || fail "unexpected extension point: $EXTENSION_POINT"

lipo "$APP_EXECUTABLE" -verify_arch arm64 >/dev/null 2>&1 || fail "app does not contain arm64"

echo "Validated AI Usage $APP_VERSION ($APP_BUILD) with embedded WidgetKit extension."
