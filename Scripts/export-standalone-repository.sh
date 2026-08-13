#!/bin/sh

set -eu

if [ "$#" -ne 1 ]; then
  echo "Usage: $0 /path/to/empty/destination" >&2
  exit 2
fi

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
DESTINATION="$1"

if [ -e "$DESTINATION" ] && [ ! -d "$DESTINATION" ]; then
  echo "Destination exists and is not a directory: $DESTINATION" >&2
  exit 1
fi
mkdir -p "$DESTINATION"
if [ -n "$(find "$DESTINATION" -mindepth 1 -maxdepth 1 -print -quit)" ]; then
  echo "Destination must be empty: $DESTINATION" >&2
  exit 1
fi

rsync -a \
  --exclude '.build/' \
  --exclude '.artifacts/' \
  --exclude '.derivedData/' \
  --exclude 'DerivedData/' \
  --exclude '.swiftpm/' \
  --exclude 'AIUsage [0-9]*.xcodeproj/' \
  --exclude '*.xcuserstate' \
  --exclude 'xcuserdata/' \
  --exclude '.DS_Store' \
  "$ROOT/" "$DESTINATION/"

echo "Standalone source tree exported to: $DESTINATION"
echo "Review identifiers, run secret scanning, then initialize a new Git repository there."
