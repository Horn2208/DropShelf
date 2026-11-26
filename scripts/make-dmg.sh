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
# Lizenztexte neben die App legen (Pfad relativ zum Repo-Wurzelverzeichnis des Skripts)
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cp "$ROOT/THIRD-PARTY-LICENSES.md" "$ROOT/LICENSE" "$STAGING/"

mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"
# Hintergrund (scripts/make-dmg-background.swift) + Fenster-/Icon-Layout; Positionen müssen zum Hintergrund passen
mkdir -p "$STAGING/.background"
cp "$ROOT/Resources/dmg/background.tiff" "$STAGING/.background/background.tiff"
RW="$STAGING.rw.dmg"
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGING" -ov -format UDRW "$RW"
MNT="$(hdiutil attach "$RW" -readwrite -noverify -noautoopen | awk -F'\t' '/\/Volumes\//{print $NF}' | tail -1)"
osascript <<OSA
tell application "Finder"
  tell disk "$VOLNAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {200, 120, 740, 500}
    set opts to icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 96
    set background picture of opts to file ".background:background.tiff"
    set position of item "$(basename "$APP")" of container window to {140, 170}
    set position of item "Applications" of container window to {400, 170}
    set position of item "THIRD-PARTY-LICENSES.md" of container window to {700, 170}
    set position of item "LICENSE" of container window to {700, 270}
    close
    open
    update without registering applications
    delay 2
    close
  end tell
end tell
OSA
sync
hdiutil detach "$MNT"
hdiutil convert "$RW" -format UDZO -o "$OUT"
rm -f "$RW"
hdiutil verify "$OUT"

if [ -n "${DEVELOPER_ID:-}" ] && [ -n "${NOTARY_PROFILE:-}" ]; then
  codesign --force --timestamp --sign "$DEVELOPER_ID" "$OUT"
  xcrun notarytool submit "$OUT" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$OUT"
  xcrun stapler validate "$OUT"
fi
