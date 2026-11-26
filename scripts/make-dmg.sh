#!/usr/bin/env bash
# Usage: scripts/make-dmg.sh <path to .app> <volume name> <output .dmg>
# Optional signing + notarization (only when both variables are set):
#   DEVELOPER_ID="Developer ID Application: Name (TEAMID)"  NOTARY_PROFILE="DropShelf-Notar"
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

if [ -n "${DEVELOPER_ID:-}" ]; then
  # Hardened Runtime + Zeitstempel; Entitlements der App bleiben erhalten.
  codesign --force --options runtime --timestamp --preserve-metadata=entitlements \
    --sign "$DEVELOPER_ID" "$APP"
  codesign --verify --deep --strict "$APP"
fi

ditto "$APP" "$STAGING/$(basename "$APP")"
ln -s /Applications "$STAGING/Applications"

mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGING" -ov -format UDZO "$OUT"
hdiutil verify "$OUT"

if [ -n "${DEVELOPER_ID:-}" ] && [ -n "${NOTARY_PROFILE:-}" ]; then
  codesign --force --timestamp --sign "$DEVELOPER_ID" "$OUT"
  xcrun notarytool submit "$OUT" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$OUT"
  xcrun stapler validate "$OUT"
fi
