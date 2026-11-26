# jxl

JPEG XL als nachladbare Codec-Dylib (ABI Version 1, siehe `../dummy/README.md`).

- Eingabe: PNG und JPEG (dekodiert mit `stb_image.h`, kein Apple-Framework in der Dylib).
  PNG mit 16 Bit wird auf 8 Bit reduziert, die EXIF-Ausrichtung von JPEG wird nicht angewendet.
- Ausgabe: `.jxl` (`targetExt` = `"jxl"`, sonst Fehler 5).
- Qualität: Distance 1.0 (visuell nahezu verlustfrei, etwa JPEG-Qualität 90), Effort 5.
- Rückgabecodes: 0 Erfolg, 1 src nicht lesbar/dekodierbar, 2 dst nicht schreibbar, 3 Schreibfehler,
  4 Encoder-Fehler, 5 Zielformat nicht unterstützt.
- Universal (arm64 + x86_64), Deployment-Ziel macOS 14, libjxl/libhwy/brotli/skcms statisch eingebaut,
  nur `dsc_*` exportiert.
- Build: `scripts/build-codec.sh jxl` (braucht `cmake` und `ninja` im PATH).
- Version: `VERSION` ist die libjxl-Version; Tag und Tarball-SHA-256 stehen in `UPSTREAM`,
  die Commit-Pins der Abhängigkeiten (aus `deps.sh` des Tarballs) mit Tarball-Hashes in `deps-resolved.txt`.
- Lizenzen: `LICENSE-libjxl` (BSD-3), `LICENSE-highway` (Apache-2.0/BSD-3), `LICENSE-brotli` (MIT),
  `LICENSE-skcms` (BSD-3), `LICENSE-stb_image` (MIT/Public Domain). stb_image.h: nothings/stb Commit
  `6b5799bae8a1fe3792691ef4b72ae26434c3e799`, SHA-256 `dfc2aadda6295f67f677587773f25e5bf8c8ad427ed0db7c518525c91e72e020`.
