#!/bin/bash
# Build-Schritt des Codecs: build.sh <ausgabe.dylib>. Das Skript signiert nicht.
set -euo pipefail
cd "$(dirname "$0")"
clang -dynamiclib -arch arm64 -arch x86_64 -mmacosx-version-min=14.0 -O2 \
  -install_name @rpath/dummy.dylib -o "$1" dummy.c
