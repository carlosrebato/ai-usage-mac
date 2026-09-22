#!/bin/sh

set -eu

if [ "$#" -ne 1 ]; then
  echo "Usage: $0 /path/to/AI\ Usage.app" >&2
  exit 2
fi

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
APP_PATH="$1"
EXECUTABLE="$APP_PATH/Contents/MacOS/AI Usage"

fail() {
  echo "Release readiness failed: $1" >&2
  exit 1
}

[ -d "$APP_PATH" ] || fail "app not found at $APP_PATH"

cd "$ROOT"
swift test --scratch-path "${TMPDIR:-/private/tmp}/ai-usage-release-tests"
"$ROOT/Scripts/validate-bundle.sh" "$APP_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

SIGNING_INFO="$(codesign -dvv "$APP_PATH" 2>&1)"
printf '%s\n' "$SIGNING_INFO" | grep -q 'Authority=Developer ID Application:' || \
  fail "Developer ID Application signature required"

ENTITLEMENTS="$(codesign -d --entitlements - --xml "$APP_PATH" 2>/dev/null)"
NORMALIZED_ENTITLEMENTS="$(printf '%s' "$ENTITLEMENTS" | tr -d '[:space:]')"
if printf '%s' "$NORMALIZED_ENTITLEMENTS" | grep -Fq \
  '<key>com.apple.security.get-task-allow</key><true/>'; then
  fail "get-task-allow is enabled; this is a development build"
fi

lipo "$EXECUTABLE" -verify_arch arm64 >/dev/null 2>&1 || \
  fail "arm64 executable slice required"
lipo "$EXECUTABLE" -verify_arch x86_64 >/dev/null 2>&1 || \
  fail "x86_64 executable slice required"
xcrun stapler validate "$APP_PATH" >/dev/null || fail "notarization ticket is missing or invalid"
spctl --assess --type execute --verbose=2 "$APP_PATH" || fail "Gatekeeper assessment failed"

AI_USAGE_EXPECTED_BUNDLE_ID="${AI_USAGE_APP_BUNDLE_ID:-com.example.aiusage}" \
  "$ROOT/Scripts/smoke-test-signed-app.sh" "$APP_PATH" 3

echo "Release readiness passed: $APP_PATH"
