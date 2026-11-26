#!/bin/bash
# Build-Schritt des WebM-Codecs: build.sh <ausgabe.dylib>. Das Skript signiert nicht.
# Braucht cmake und ninja im PATH (für libopus) sowie make und die Xcode Command Line Tools (für libvpx).
# Lädt libvpx und libopus (Hashes siehe UPSTREAM).
set -euo pipefail
cd "$(dirname "$0")"
HERE="$PWD"
OUT="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
. ./UPSTREAM
WORK="${DSC_WORK:-$(mktemp -d)}"
mkdir -p "$WORK/dl"

fetch() { # name url sha256
  if [ ! -d "$WORK/$1" ]; then
    curl -fsSL -o "$WORK/dl/$1.tgz" "$2"
    [ "$(shasum -a 256 "$WORK/dl/$1.tgz" | cut -d' ' -f1)" = "$3" ] || { echo "$1 SHA-256 stimmt nicht" >&2; exit 1; }
    mkdir "$WORK/$1" && tar xzf "$WORK/dl/$1.tgz" -C "$WORK/$1" --strip-components=1
  fi
}
fetch vpx "https://github.com/webmproject/libvpx/archive/refs/tags/$VPX_TAG.tar.gz" "$VPX_SHA256"
fetch opus "https://github.com/xiph/opus/archive/refs/tags/$OPUS_TAG.tar.gz" "$OPUS_SHA256"

for arch in arm64 x86_64; do
  # libvpx: nur VP9-Encoder. arm64 mit NEON. Für x86_64 fehlt ohne nasm/yasm der Assembler, daher dort das
  # generische C-Target (ohne SIMD, langsamer auf Intel-Macs, aber ohne weiteres Build-Werkzeug).
  V="$WORK/vpx-build-$arch"; mkdir -p "$V"
  if [ "$arch" = x86_64 ]; then tgt=generic-gnu; else tgt="$arch-darwin23-gcc"; fi
  ( cd "$V" && CC="clang -arch $arch" CXX="clang++ -arch $arch" LD="clang++ -arch $arch" \
      "$WORK/vpx/configure" --target="$tgt" --enable-pic --disable-examples --disable-tools --disable-docs \
      --disable-unit-tests --disable-install-bins --disable-vp8 --enable-vp9 --disable-vp9-decoder \
      --extra-cflags="-mmacosx-version-min=14.0" >/dev/null \
    && make -j"$(sysctl -n hw.ncpu)" libvpx.a >/dev/null )
  O="$WORK/opus-build-$arch"
  cmake -S "$WORK/opus" -B "$O" -G Ninja -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES=$arch -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DBUILD_SHARED_LIBS=OFF -DOPUS_BUILD_PROGRAMS=OFF \
    -DOPUS_BUILD_TESTING=OFF -DOPUS_INSTALL_PKG_CONFIG_MODULE=OFF -DOPUS_INSTALL_CMAKE_CONFIG_MODULE=OFF
  cmake --build "$O" --target opus >/dev/null
  clang -dynamiclib -arch $arch -mmacosx-version-min=14.0 -O2 -fvisibility=hidden \
    -I"$WORK/vpx" -I"$WORK/opus/include" "$HERE/dsc_webm.c" \
    "$V/libvpx.a" "$(find "$O" -name libopus.a)" -dead_strip -Wl,-exported_symbols_list,"$HERE/exports.txt" \
    -install_name @rpath/webm.dylib -o "$WORK/webm-$arch.dylib"
done
lipo -create "$WORK"/webm-arm64.dylib "$WORK"/webm-x86_64.dylib -output "$OUT"
[ -z "${DSC_WORK:-}" ] && rm -rf "$WORK"
exit 0
