#!/bin/bash
# Build-Schritt des JPEG-XL-Codecs: build.sh <ausgabe.dylib>. Das Skript signiert nicht.
# Braucht cmake und ninja im PATH. Lädt libjxl und dessen Abhängigkeiten (Hashes siehe UPSTREAM).
set -euo pipefail
cd "$(dirname "$0")"
HERE="$PWD"
OUT="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
. ./UPSTREAM
WORK="${DSC_WORK:-$(mktemp -d)}"
mkdir -p "$WORK/dl"

# libjxl-Release-Tarball, SHA-256 geprüft
if [ ! -d "$WORK/src" ]; then
  curl -fsSL -o "$WORK/dl/jxl.tgz" "https://github.com/libjxl/libjxl/archive/refs/tags/$JXL_TAG.tar.gz"
  [ "$(shasum -a 256 "$WORK/dl/jxl.tgz" | cut -d' ' -f1)" = "$JXL_SHA256" ] || { echo "libjxl SHA-256 stimmt nicht" >&2; exit 1; }
  mkdir "$WORK/src" && tar xzf "$WORK/dl/jxl.tgz" -C "$WORK/src" --strip-components=1
  # Submodule: Commit-Pins stehen in deps.sh des Release-Tarballs
  for dep in brotli:google/brotli highway:google/highway skcms:google/skcms; do
    name="${dep%%:*}"; repo="${dep#*:}"
    var="THIRD_PARTY_$(echo "$name" | tr a-z A-Z)"
    sha="$(sed -n "s/^$var=\"\([0-9a-f]*\)\".*/\1/p" "$WORK/src/deps.sh")"
    [ -n "$sha" ] || { echo "kein Pin für $name" >&2; exit 1; }
    curl -fsSL -o "$WORK/dl/$name.tgz" "https://github.com/$repo/tarball/$sha"
    echo "$name $repo $sha $(shasum -a 256 "$WORK/dl/$name.tgz" | cut -d' ' -f1)" >> "$WORK/deps.txt"
    tar xzf "$WORK/dl/$name.tgz" -C "$WORK/src/third_party/$name" --strip-components=1
  done
fi

for arch in arm64 x86_64; do
  B="$WORK/build-$arch"
  cmake -S "$WORK/src" -B "$B" -G Ninja -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES=$arch -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=OFF \
    -DJPEGXL_STATIC=ON -DJPEGXL_ENABLE_TOOLS=OFF -DJPEGXL_ENABLE_DEVTOOLS=OFF \
    -DJPEGXL_ENABLE_BENCHMARK=OFF -DJPEGXL_ENABLE_EXAMPLES=OFF -DJPEGXL_ENABLE_MANPAGES=OFF \
    -DJPEGXL_ENABLE_PLUGINS=OFF -DJPEGXL_ENABLE_JNI=OFF -DJPEGXL_ENABLE_SJPEG=OFF \
    -DJPEGXL_ENABLE_OPENEXR=OFF -DJPEGXL_ENABLE_JPEGLI=OFF -DJPEGXL_ENABLE_SKCMS=ON \
    -DJPEGXL_ENABLE_DOXYGEN=OFF -DJPEGXL_ENABLE_VIEWERS=OFF -DJPEGXL_ENABLE_COVERAGE=OFF \
    -DJPEGXL_ENABLE_TRANSCODE_JPEG=ON -DJPEGXL_ENABLE_BOXES=ON -DJPEGXL_BUNDLE_LIBPNG=OFF \
    -DJPEGXL_FORCE_SYSTEM_BROTLI=OFF -DJPEGXL_FORCE_SYSTEM_HWY=OFF
  cmake --build "$B" --target jxl_threads jxl >/dev/null
  # alle statischen Libs dieses Builds zu einer Liste sammeln
  libs=$(find "$B" -name '*.a' ! -name 'libgtest*' | tr '\n' ' ')
  # shellcheck disable=SC2086
  clang++ -dynamiclib -arch $arch -mmacosx-version-min=14.0 -O2 -fvisibility=hidden \
    -I"$WORK/src/lib/include" -I"$B/lib/include" -I"$HERE" -x c "$HERE/dsc_jxl.c" -x none \
    -Wl,-force_load,"$(find "$B" -name libjxl.a)" -Wl,-force_load,"$(find "$B" -name libjxl_threads.a)" \
    $libs -lc++ -dead_strip -Wl,-exported_symbols_list,"$HERE/exports.txt" \
    -install_name @rpath/jxl.dylib -o "$WORK/jxl-$arch.dylib"
done
lipo -create "$WORK"/jxl-arm64.dylib "$WORK"/jxl-x86_64.dylib -output "$OUT"
cp "$WORK/deps.txt" "$HERE/deps-resolved.txt" 2>/dev/null || true
[ -z "${DSC_WORK:-}" ] && rm -rf "$WORK"
exit 0
