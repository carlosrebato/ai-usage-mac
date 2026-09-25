#!/bin/sh

set -eu

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
  echo "Usage: $0 RELEASE_TAG /path/to/release-archives [stable|beta]" >&2
  exit 2
fi

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
RELEASE_TAG="$1"
ARCHIVES="$2"
CHANNEL="${3:-stable}"
GENERATOR="$ROOT/.build/artifacts/sparkle/Sparkle/bin/generate_appcast"

case "$CHANNEL" in
  stable) set -- ;;
  beta) set -- --channel beta ;;
  *) echo "Unknown update channel: $CHANNEL" >&2; exit 2 ;;
esac

case "$RELEASE_TAG" in
  *-*)
    if [ "$CHANNEL" != beta ]; then
      echo "Prerelease tags must use the beta update channel: $RELEASE_TAG" >&2
      exit 2
    fi
    ;;
esac

[ -x "$GENERATOR" ] || {
  echo "Sparkle tools are missing. Run 'swift package resolve' first." >&2
  exit 1
}
[ -d "$ARCHIVES" ] || {
  echo "Archive directory not found: $ARCHIVES" >&2
  exit 1
}

"$GENERATOR" \
  "$@" \
  --account com.carlosrebato.aiusage \
  --download-url-prefix "https://github.com/carlosrebato/ai-usage-mac/releases/download/$RELEASE_TAG/" \
  --link "https://github.com/carlosrebato/ai-usage-mac" \
  --full-release-notes-url "https://github.com/carlosrebato/ai-usage-mac/releases" \
  -o "$ARCHIVES/appcast.xml" \
  "$ARCHIVES"

echo "Generated signed appcast: $ARCHIVES/appcast.xml"
