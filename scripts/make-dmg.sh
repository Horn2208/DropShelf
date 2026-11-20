#!/usr/bin/env bash
# Usage: scripts/make-dmg.sh <path to .app> <volume name> <output .dmg>
set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "usage: $0 <path to .app> <volume name> <output .dmg>" >&2
  exit 1
fi

APP="$1"
VOLNAME="$2"
OUT="$3"

if [ ! -d "$APP" ]; then
  echo "error: app bundle not found: $APP" >&2
  exit 1
fi

STAGING="$(mktemp -d "${TMPDIR:-/tmp}/make-dmg.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT

ditto "$APP" "$STAGING/$(basename "$APP")"
ln -s /Applications "$STAGING/Applications"

mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGING" -ov -format UDZO "$OUT"
hdiutil verify "$OUT"
