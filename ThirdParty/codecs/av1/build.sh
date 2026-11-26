#!/bin/bash
# Build-Schritt des AV1-Codecs: build.sh <ausgabe.dylib>. Das Skript signiert nicht.
# Braucht cmake und ninja im PATH und die Xcode Command Line Tools. Lädt libaom (Hash siehe UPSTREAM).
set -euo pipefail
cd "$(dirname "$0")"
HERE="$PWD"
OUT="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
. ./UPSTREAM
WORK="${DSC_WORK:-$(mktemp -d)}"
mkdir -p "$WORK/dl"

if [ ! -d "$WORK/aom" ]; then
  curl -fsSL -o "$WORK/dl/aom.tgz" "$AOM_URL"
  [ "$(shasum -a 256 "$WORK/dl/aom.tgz" | cut -d' ' -f1)" = "$AOM_SHA256" ] || { echo "libaom SHA-256 stimmt nicht" >&2; exit 1; }
  mkdir "$WORK/aom" && tar xzf "$WORK/dl/aom.tgz" -C "$WORK/aom" --strip-components=1
fi

for arch in arm64 x86_64; do
  # Nur Encoder. Auf x86_64 ohne nasm: generisches C-Target (ohne SIMD, langsamer auf Intel-Macs).
  cpu=""; [ "$arch" = x86_64 ] && cpu="-DAOM_TARGET_CPU=generic -DCONFIG_RUNTIME_CPU_DETECT=0"
  O="$WORK/aom-build-$arch"
  cmake -S "$WORK/aom" -B "$O" -G Ninja -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES=$arch -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DBUILD_SHARED_LIBS=OFF \
    -DCONFIG_AV1_DECODER=0 -DCONFIG_AV1_ENCODER=1 -DENABLE_TESTS=0 -DENABLE_EXAMPLES=0 \
    -DENABLE_DOCS=0 -DENABLE_TOOLS=0 -DENABLE_TESTDATA=0 -DENABLE_NASM=0 -DENABLE_CCACHE=0 $cpu >/dev/null
  cmake --build "$O" --target aom >/dev/null
  clang -dynamiclib -arch $arch -mmacosx-version-min=14.0 -O2 -fvisibility=hidden \
    -I"$WORK/aom" -I"$O" "$HERE/dsc_av1.c" "$O/libaom.a" -dead_strip \
    -Wl,-exported_symbols_list,"$HERE/exports.txt" -install_name @rpath/av1.dylib -o "$WORK/av1-$arch.dylib"
done
lipo -create "$WORK"/av1-arm64.dylib "$WORK"/av1-x86_64.dylib -output "$OUT"
[ -z "${DSC_WORK:-}" ] && rm -rf "$WORK"
exit 0
