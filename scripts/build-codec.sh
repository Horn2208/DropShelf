#!/bin/bash
# Baut, signiert und notarisiert eine Codec-Dylib: scripts/build-codec.sh <name>
# Quelle: ThirdParty/codecs/<name>/ (build.sh, VERSION). Ausgabe: dist/codecs/.
set -euo pipefail
NAME="${1:?usage: build-codec.sh <name>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/ThirdParty/codecs/$NAME"
OUT="$ROOT/dist/codecs"
IDENTITY="${DEVELOPER_ID:-Developer ID Application: Lennet Joel Schierhorn (B892A3M49U)}"
PROFILE="${NOTARY_PROFILE:-DropShelf-Notar}"
VERSION="$(tr -d '[:space:]' < "$SRC/VERSION")"
DYLIB="$OUT/$NAME-$VERSION.dylib"

mkdir -p "$OUT"
"$SRC/build.sh" "$DYLIB"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$DYLIB"
codesign --verify --strict "$DYLIB"

# notarytool nimmt keine nackte Dylib, daher ein Zip nur für die Einreichung.
ZIP="$OUT/$NAME-$VERSION.zip"
rm -f "$ZIP"; ditto -c -k --keepParent "$DYLIB" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait | tee "$OUT/$NAME-notarize.log"
grep -q "status: Accepted" "$OUT/$NAME-notarize.log" || { echo "Notarisierung nicht akzeptiert" >&2; exit 1; }

# Ausgeliefert wird die Dylib selbst, der Hash gilt für sie (siehe PackDownloader).
SHA="$(shasum -a 256 "$DYLIB" | cut -d' ' -f1)"
cat > "$OUT/$NAME-manifest-entry.json" <<JSON
{
  "id": "$NAME",
  "version": "$VERSION",
  "url": "TODO",
  "sha256": "$SHA",
  "formats": [],
  "apiVersion": 1
}
JSON
echo "OK: $DYLIB sha256=$SHA"
