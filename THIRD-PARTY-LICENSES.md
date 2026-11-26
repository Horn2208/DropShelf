# Third-Party Licenses

DropShelf bindet quelloffene Encoder-Bibliotheken statisch als Quellcode über das lokale SwiftPM-Paket [`ThirdParty/DropShelfCodecs`](ThirdParty/DropShelfCodecs) ein (keine externen Kindprozesse, kein Nachladen zur Laufzeit).

## Übersicht

| Bibliothek | Version | Lizenz | Quelle | Status | Paket |
|---|---|---|---|---|---|
| libogg | 1.3.6 | BSD-3-Clause | https://xiph.org/ogg/ (https://ftp.osuosl.org/pub/xiph/releases/ogg/libogg-1.3.6.tar.gz) | eingebunden | 18.2 |
| libvorbis | 1.3.7 | BSD-3-Clause | https://xiph.org/vorbis/ (https://ftp.osuosl.org/pub/xiph/releases/vorbis/libvorbis-1.3.7.tar.xz) | eingebunden | 18.2 |
| libopus | 1.6.1 | BSD-3-Clause | https://opus-codec.org/ (https://ftp.osuosl.org/pub/xiph/releases/opus/opus-1.6.1.tar.gz) | eingebunden | 18.2 |
| libFLAC (nur Bibliothek `src/libFLAC`, ohne GPL-CLI) | 1.5.0 | BSD-3-Clause | https://xiph.org/flac/ (https://ftp.osuosl.org/pub/xiph/releases/flac/flac-1.5.0.tar.xz) | eingebunden | 18.2 |
| libmp3lame | 3.100 | LGPL-2.0-or-later | https://lame.sourceforge.io/ (https://downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz) | eingebunden | 18.3 |
| libwebp | 1.6.0 | BSD-3-Clause | https://chromium.googlesource.com/webm/libwebp (https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-1.6.0.tar.gz) | eingebunden | 18.4 |
| libwavpack | 5.9.0 | BSD-3-Clause | https://www.wavpack.com/ (https://www.wavpack.com/wavpack-5.9.0.tar.bz2) | eingebunden | 18.4 |
| FFmpeg (LGPL-Konfiguration ohne GPL-Komponenten) | – | LGPL-2.1-or-later | https://ffmpeg.org/ | nicht eingebunden (bewusst weggelassen: +10–26 MB Zuwachs, externer Buildpfad) | 18.5 |

## Lizenzhinweise

- **BSD-3-Clause (libogg, libvorbis, libopus, libFLAC, libwebp, libwavpack):** Statisches Einbinden ist uneingeschränkt erlaubt, sofern Copyright-Vermerk und Lizenztext bei der Weitergabe beigelegt werden. Für `flac` werden ausschließlich die BSD-lizenzierten Bibliotheksteile (`src/libFLAC`, `include/FLAC`, `include/share`) eingebunden; die GPL-lizenzierten Kommandozeilenprogramme (`src/flac`, `src/metaflac`) werden nicht aufgenommen.
- **LGPL-2.0-or-later (libmp3lame):** Da DropShelf als Open-Source-Projekt (mit Quellcode) weitergegeben wird, ist das statische Linken von `libmp3lame` LGPL-konform. Die Original-Lizenzdatei liegt unter `ThirdParty/DropShelfCodecs/Sources/CLame/COPYING`.

## Vollständige Lizenztexte

*(Die Original-Lizenztexte `COPYING` / `LICENSE` werden mit jedem Paket in `ThirdParty/DropShelfCodecs/Sources/<Target>/` abgelegt und hier ergänzt.)*
