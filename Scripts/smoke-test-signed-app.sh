#!/bin/sh

set -eu

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  echo "Usage: $0 /path/to/AI\ Usage.app [relaunch-count]" >&2
  exit 2
fi

APP_PATH="$1"
RELAUNCH_COUNT="${2:-3}"
EXECUTABLE="$APP_PATH/Contents/MacOS/AI Usage"
REPORT_DIR="${TMPDIR:-/private/tmp}/ai-usage-smoke"
EXPECTED_BUNDLE_ID="${AI_USAGE_EXPECTED_BUNDLE_ID:-}"

[ -d "$APP_PATH" ] || { echo "App not found: $APP_PATH" >&2; exit 1; }
[ -x "$EXECUTABLE" ] || { echo "Executable not found: $EXECUTABLE" >&2; exit 1; }
case "$RELAUNCH_COUNT" in
  *[!0-9]*|'') echo "Relaunch count must be a positive integer." >&2; exit 2 ;;
esac
[ "$RELAUNCH_COUNT" -gt 0 ] || { echo "Relaunch count must be positive." >&2; exit 2; }

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
SIGNING_INFO="$(codesign -dvv "$APP_PATH" 2>&1)"
TEAM_ID="$(printf '%s\n' "$SIGNING_INFO" | sed -n 's/^TeamIdentifier=//p')"
AUTHORITY="$(printf '%s\n' "$SIGNING_INFO" | sed -n 's/^Authority=//p' | head -n 1)"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Contents/Info.plist")"
APP_ENTITLEMENTS="$(codesign -d --entitlements - --xml "$APP_PATH" 2>/dev/null)"
NORMALIZED_APP_ENTITLEMENTS="$(printf '%s' "$APP_ENTITLEMENTS" | tr -d '[:space:]')"

if [ -n "$EXPECTED_BUNDLE_ID" ] && [ "$BUNDLE_ID" != "$EXPECTED_BUNDLE_ID" ]; then
  echo "Unexpected bundle identifier: $BUNDLE_ID" >&2
  exit 1
fi
[ -n "$TEAM_ID" ] && [ "$TEAM_ID" != "not set" ] || {
  echo "A stable Apple Development or Developer ID signature is required." >&2
  exit 1
}
[ -n "$AUTHORITY" ] || {
  echo "The app has no trusted signing authority; ad-hoc builds cannot test TCC persistence." >&2
  exit 1
}
if ! printf '%s' "$NORMALIZED_APP_ENTITLEMENTS" | grep -Fq '<key>com.apple.security.app-sandbox</key><true/>'; then
  echo "The signed app is missing App Sandbox; App Group access may prompt on every launch." >&2
  exit 1
fi
if ! printf '%s' "$NORMALIZED_APP_ENTITLEMENTS" | grep -Fq '<key>com.apple.security.network.server</key><true/>'; then
  echo "The signed app cannot receive the local OAuth callback." >&2
  exit 1
fi
EXPECTED_KEYCHAIN_GROUP="$TEAM_ID.$BUNDLE_ID"
if ! printf '%s' "$NORMALIZED_APP_ENTITLEMENTS" | grep -Fq "<key>keychain-access-groups</key><array><string>$EXPECTED_KEYCHAIN_GROUP</string>"; then
  echo "The signed app is missing its OAuth Keychain access group: $EXPECTED_KEYCHAIN_GROUP" >&2
  exit 1
fi

KEYCHAIN_REPORT="$($EXECUTABLE --verify-oauth-keychain)"
if ! printf '%s' "$KEYCHAIN_REPORT" | grep -Eq '"keychainAccess"[[:space:]]*:[[:space:]]*true'; then
  echo "The signed app cannot write and read its OAuth token in Keychain:" >&2
  printf '%s\n' "$KEYCHAIN_REPORT" >&2
  exit 1
fi

mkdir -p "$REPORT_DIR"
iteration=1
while [ "$iteration" -le "$RELAUNCH_COUNT" ]; do
  REPORT_PATH="$REPORT_DIR/run-$iteration.json"
  rm -f "$REPORT_PATH"
  # A sandboxed app cannot write to the caller's arbitrary temporary folder.
  # Capture its JSON stdout from outside the sandbox instead.
  "$EXECUTABLE" --smoke-test > "$REPORT_PATH"
  [ -f "$REPORT_PATH" ] || { echo "Run $iteration produced no report." >&2; exit 1; }
  if ! grep -Eq '"permissionsPersisted"[[:space:]]*:[[:space:]]*true' "$REPORT_PATH" ||
     ! grep -Eq '"hasUsageData"[[:space:]]*:[[:space:]]*true' "$REPORT_PATH" ||
     grep -Eq '"connection"[[:space:]]*:[[:space:]]*"(missing|action-required:)' "$REPORT_PATH"; then
    echo "Run $iteration needs attention. Permissions and usable provider data must persist:" >&2
    cat "$REPORT_PATH" >&2
    exit 1
  fi
  if grep -Eq '"hasLiveData"[[:space:]]*:[[:space:]]*true' "$REPORT_PATH"; then
    echo "Smoke run $iteration/$RELAUNCH_COUNT passed with live data."
  else
    echo "Smoke run $iteration/$RELAUNCH_COUNT passed with persisted permissions and cached data (provider rate limit)."
  fi
  iteration=$((iteration + 1))
done

echo "Signed smoke test passed across $RELAUNCH_COUNT launches."
echo "Bundle identifier: $BUNDLE_ID"
echo "Team identifier: $TEAM_ID"
echo "Signing authority: $AUTHORITY"
echo "Reports: $REPORT_DIR"
