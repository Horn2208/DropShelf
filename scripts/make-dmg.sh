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

# Python mit den Paketen ds_store und mac_alias (z. B. venv: pip install ds_store)
DS_PY="${DS_STORE_PYTHON:-python3}"
if ! "$DS_PY" -c 'import ds_store, mac_alias' 2>/dev/null; then
  echo "error: $DS_PY lacks ds_store/mac_alias; set DS_STORE_PYTHON to a python with 'pip install ds_store'" >&2
  exit 1
fi

STAGING="$(mktemp -d "${TMPDIR:-/tmp}/make-dmg.XXXXXX")"
trap 'rm -rf "$STAGING" "$STAGING.py"' EXIT

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
# Layout direkt in die .DS_Store schreiben (wie dmgbuild): Finder per AppleScript speichert unter
# aktuellem macOS die Darstellungsoptionen (Hintergrund, Icon-Größe) nicht mehr zuverlässig.
# -nobrowse hält Finder vom Volume fern, damit er die Datei nicht überschreibt.
cat > "$STAGING.py" <<'PY'
import sys
from ds_store import DSStore
from mac_alias import Alias, Bookmark
mnt, app, mode = sys.argv[1:]
bg = mnt + "/.background/background.tiff"
pos = {app: (140, 170), "Applications": (400, 170), "THIRD-PARTY-LICENSES.md": (700, 170), "LICENSE": (700, 270)}
bounds = "{{200, 120}, {540, 380}}"
if mode == "write":
    with DSStore.open(mnt + "/.DS_Store", "w+") as d:
        d["."]["bwsp"] = {"WindowBounds": bounds, "ShowStatusBar": False, "ShowToolbar": False, "ShowPathbar": False,
                          "ShowSidebar": False, "ContainerShowSidebar": False, "ShowTabView": False}
        d["."]["icvp"] = {"viewOptionsVersion": 1, "backgroundType": 2, "backgroundImageAlias": Alias.for_file(bg).to_bytes(),
                          "arrangeBy": "none", "iconSize": 96.0, "textSize": 12.0, "labelOnBottom": True,
                          "gridSpacing": 100.0, "gridOffsetX": 0.0, "gridOffsetY": 0.0, "showItemInfo": False,
                          "showIconPreview": True, "scrollPositionX": 0.0, "scrollPositionY": 0.0,
                          "backgroundColorRed": 1.0, "backgroundColorGreen": 1.0, "backgroundColorBlue": 1.0}
        d["."]["pBBk"] = Bookmark.for_file(bg)
        d["."]["vSrn"] = ("long", 1)
        d["."]["vstl"] = ("type", b"icnv")
        for name, p in pos.items():
            d[name]["Iloc"] = p
else:  # check: Layout muss vollständig in der fertigen DMG stehen
    with DSStore.open(mnt + "/.DS_Store", "r") as d:
        def get(name, code):
            try: return d[name][code]
            except KeyError: return None
        icvp, alias = get(".", "icvp") or {}, None
        if icvp.get("backgroundImageAlias"): alias = Alias.from_bytes(icvp["backgroundImageAlias"]).target.filename
        errors = []
        if (get(".", "bwsp") or {}).get("WindowBounds") != bounds: errors.append("window bounds")
        if icvp.get("backgroundType") != 2 or alias != "background.tiff": errors.append("background")
        if icvp.get("iconSize") != 96.0: errors.append("icon size")
        errors += ["position " + n for n, p in pos.items() if get(n, "Iloc") != p]
    if errors:
        sys.exit("error: .DS_Store layout incomplete: " + ", ".join(errors))
    print(".DS_Store layout ok")
PY
MNT="$(hdiutil attach "$RW" -readwrite -noverify -noautoopen -nobrowse | awk -F'\t' '/\/Volumes\//{print $NF}' | tail -1)"
"$DS_PY" "$STAGING.py" "$MNT" "$(basename "$APP")" write
sync
hdiutil detach "$MNT"
hdiutil convert "$RW" -format UDZO -o "$OUT"
rm -f "$RW"
hdiutil verify "$OUT"
MNT="$(hdiutil attach "$OUT" -readonly -nobrowse -noverify -noautoopen | awk -F'\t' '/\/Volumes\//{print $NF}' | tail -1)"
"$DS_PY" "$STAGING.py" "$MNT" "$(basename "$APP")" check || { hdiutil detach "$MNT"; exit 1; }
hdiutil detach "$MNT"

if [ -n "${DEVELOPER_ID:-}" ] && [ -n "${NOTARY_PROFILE:-}" ]; then
  codesign --force --timestamp --sign "$DEVELOPER_ID" "$OUT"
  xcrun notarytool submit "$OUT" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$OUT"
  xcrun stapler validate "$OUT"
fi
