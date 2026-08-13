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

mkdir -p "$REPORT_DIR"
iteration=1
while [ "$iteration" -le "$RELAUNCH_COUNT" ]; do
  REPORT_PATH="$REPORT_DIR/run-$iteration.json"
  rm -f "$REPORT_PATH"
  "$EXECUTABLE" --smoke-test --smoke-report "$REPORT_PATH"
  [ -f "$REPORT_PATH" ] || { echo "Run $iteration produced no report." >&2; exit 1; }
  if ! grep -Eq '"passed"[[:space:]]*:[[:space:]]*true' "$REPORT_PATH"; then
    echo "Run $iteration needs attention. Login, macOS permission or usable cached data is missing:" >&2
    cat "$REPORT_PATH" >&2
    exit 1
  fi
  echo "Smoke run $iteration/$RELAUNCH_COUNT passed."
  iteration=$((iteration + 1))
done

echo "Signed smoke test passed across $RELAUNCH_COUNT launches."
echo "Bundle identifier: $BUNDLE_ID"
echo "Team identifier: $TEAM_ID"
echo "Signing authority: $AUTHORITY"
echo "Reports: $REPORT_DIR"
