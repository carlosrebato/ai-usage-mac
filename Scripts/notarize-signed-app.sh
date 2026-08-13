#!/bin/sh

set -eu

if [ "$#" -ne 2 ]; then
  echo "Usage: $0 /path/to/AI\ Usage.app NOTARY_KEYCHAIN_PROFILE" >&2
  exit 2
fi

APP_PATH="$1"
KEYCHAIN_PROFILE="$2"
APP_PARENT="$(CDPATH= cd -- "$(dirname -- "$APP_PATH")" && pwd)"
APP_NAME="$(basename -- "$APP_PATH")"
BASE_NAME="${APP_NAME%.app}"
SUBMISSION_ZIP="$APP_PARENT/$BASE_NAME-notarization.zip"
FINAL_ZIP="$APP_PARENT/$BASE_NAME-notarized.zip"

[ -d "$APP_PATH" ] || { echo "App not found: $APP_PATH" >&2; exit 1; }

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
SIGNING_INFO="$(codesign -dvv "$APP_PATH" 2>&1)"
echo "$SIGNING_INFO" | grep -q 'Authority=Developer ID Application:' || {
  echo "The app is not signed with a Developer ID Application certificate." >&2
  exit 1
}

rm -f "$SUBMISSION_ZIP" "$FINAL_ZIP"
ditto -c -k --keepParent "$APP_PATH" "$SUBMISSION_ZIP"
xcrun notarytool submit "$SUBMISSION_ZIP" --keychain-profile "$KEYCHAIN_PROFILE" --wait
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"
spctl --assess --type execute --verbose=2 "$APP_PATH"
ditto -c -k --keepParent "$APP_PATH" "$FINAL_ZIP"
rm -f "$SUBMISSION_ZIP"

echo "Notarized release artifact: $FINAL_ZIP"
