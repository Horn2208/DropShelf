# webm

WebM mit VP9-Video und Opus-Audio als nachladbare Codec-Dylib (ABI Version 1, siehe `../dummy/README.md`).

## Eingabe (Umfang)

Die ABI kennt nur Dateipfade, und die Dylib nutzt keine Apple-Frameworks. Sie kann deshalb keine Container
wie MP4/MOV/MKV/AVI dekodieren. Angenommen wird genau:

- **YUV4MPEG2 (`.y4m`)**, unkomprimiert, 8 Bit, Chroma 4:2:0 (`C420`, `C420jpeg`, `C420mpeg2`, `C420paldv`
  oder ohne `C`-Angabe). Breite und Höhe 1 bis 16384, ungerade Maße sind erlaubt. Bildrate aus `F<n>:<d>`
  (ohne Angabe 30). Die Frame-Header (`FRAME` mit optionalen Parametern) werden gelesen, Parameter ignoriert.
- Abgelehnt (Rückgabe 1): jede andere Datei, 4:2:2, 4:4:4, Mono, 10/12 Bit, null Bilder. Ein abgeschnittenes
  letztes Bild wird verworfen.

Die App muss für Videos aus MP4/MOV/WebM-Quellen das Quellvideo vorher selbst nach y4m dekodieren
(zum Beispiel mit AVFoundation) und das Ergebnis an die Dylib geben. Ohne diesen Schritt ist der Codec
für normale Videodateien nicht nutzbar; er ist hier bewusst nicht eingebaut.

## Ausgabe

- `.webm` (`targetExt` = `"webm"`, sonst Fehler 5), Matroska-Subset nach WebM-Spezifikation (DocType `webm`).
- Video: VP9 (`V_VP9`), konstante Qualität (`VPX_Q`) mit CQ-Level 35 (0 bis 63, kleiner = besser),
  `cpu-used` 4, Qualitätsmodus Good, Keyframe höchstens alle 128 Bilder, 4 Threads.
- Audio: Opus (`A_OPUS`) 48 kHz Stereo, 96 kbit/s, 20-ms-Pakete. Es ist immer eine stille Spur über die
  Videolänge, weil die ABI keine Audioquelle kennt.
- Muxer: eigener Code in `dsc_webm.c` (Segment mit Info, Tracks, Clustern zu je 5 s, SimpleBlocks,
  Zeitskala 1 ms). Ohne Cues und SeekHead: abspielbar, Springen funktioniert in manchen Playern nur langsam.
- Alles wird im Speicher gepuffert, große Videos brauchen entsprechend RAM (etwa Größe der Ausgabedatei).

Rückgabecodes: 0 Erfolg, 1 src nicht lesbar oder kein gültiges y4m, 2 dst nicht schreibbar,
3 Schreibfehler, 4 Encoder-Fehler, 5 Zielformat nicht unterstützt.

## Build

`scripts/build-codec.sh webm`. Braucht im PATH `cmake` und `ninja` (für libopus; zum Beispiel
`pip install cmake ninja` in ein venv oder `brew install cmake ninja`), dazu `make` und die Xcode
Command Line Tools (für libvpx). Kein nasm/yasm nötig.

- Universal (arm64 + x86_64), Deployment-Ziel macOS 14, libvpx und libopus statisch eingebaut, nur `dsc_*` exportiert.
- arm64 nutzt die NEON-Pfade von libvpx. x86_64 baut mit dem generischen C-Target von libvpx (ohne SIMD,
  weil kein Assembler vorausgesetzt wird); das Kodieren ist auf Intel-Macs deshalb langsamer.
- `VERSION` ist die libvpx-Version. Tags und Tarball-SHA-256 stehen in `UPSTREAM`.

## Lizenzen

`LICENSE-libvpx` (BSD-3) mit `PATENTS-libvpx` (Patent-Grant), `LICENSE-libopus` (BSD-3).
Der Muxer in `dsc_webm.c` ist eigener Code und fällt unter die Repo-Lizenz.
