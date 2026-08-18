#!/bin/sh

set -eu

if [ "$#" -ne 2 ]; then
  echo "Usage: $0 RELEASE_TAG /path/to/release-archives" >&2
  exit 2
fi

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
RELEASE_TAG="$1"
ARCHIVES="$2"
GENERATOR="$ROOT/.build/artifacts/sparkle/Sparkle/bin/generate_appcast"

[ -x "$GENERATOR" ] || {
  echo "Sparkle tools are missing. Run 'swift package resolve' first." >&2
  exit 1
}
[ -d "$ARCHIVES" ] || {
  echo "Archive directory not found: $ARCHIVES" >&2
  exit 1
}

"$GENERATOR" \
  --account com.carlosrebato.aiusage \
  --download-url-prefix "https://github.com/carlosrebato/ai-usage-mac/releases/download/$RELEASE_TAG/" \
  --link "https://github.com/carlosrebato/ai-usage-mac" \
  --full-release-notes-url "https://github.com/carlosrebato/ai-usage-mac/releases" \
  -o "$ARCHIVES/appcast.xml" \
  "$ARCHIVES"

echo "Generated signed appcast: $ARCHIVES/appcast.xml"
