# av1

AV1-Video (libaom) als nachladbare Codec-Dylib (ABI Version 1, siehe `../dummy/README.md`).

## Eingabe (Umfang)

Wie beim WebM-Codec: nur **YUV4MPEG2 (`.y4m`)**, unkomprimiert, 8 Bit, Chroma 4:2:0, Breite und Höhe 1 bis 16384.
Alles andere gibt 1 zurück (4:2:2/4:4:4, Mono, 10/12 Bit, null Bilder). Die Dylib nutzt keine Apple-Frameworks und
dekodiert keine MP4/MOV/MKV-Quellen; die App muss das Quellvideo vorher selbst nach y4m dekodieren. Der y4m-Parser ist
aus `../webm/dsc_webm.c` kopiert (kein Link über Codec-Verzeichnisse).

## Ausgabe

- `targetExt` `"webm"` oder `"mkv"` (sonst 5). Beides schreibt dieselbe Datei: WebM (Matroska-Subset, DocType `webm`)
  mit einer Video-Spur `V_AV1`, CodecPrivate = av1C plus Sequence-Header-OBU. Es gibt keinen eigenen MKV-Modus; wer `.mkv` will, benennt die Datei um.
- **Nur Video, keine Audiospur** (die ABI kennt keine Audioquelle).
- Temporal-Delimiter-OBUs werden pro Paket entfernt (Matroska-Vorgabe). Muxer wie in `../webm` (Cluster zu 5 s,
  SimpleBlocks, 1 ms Zeitskala, ohne Cues/SeekHead). Alles wird im Speicher gepuffert.

Rückgabecodes: 0 Erfolg, 1 src nicht lesbar/kein gültiges y4m, 2 dst nicht schreibbar, 3 Schreibfehler,
4 Encoder-Fehler, 5 Zielformat nicht unterstützt.

## Qualität und Geschwindigkeit

Konstante Qualität (`AOM_Q`), CQ-Level 32 (0 bis 63, kleiner = besser und größer), `cpu-used` 6 (0 = langsamst/beste Kompression
bis 8 = schnellst), Good-Quality-Modus, Keyframe höchstens alle 128 Bilder, 4 Threads. Höhere cpu-used-Werte sparen Zeit
auf Kosten von Dateigröße bei gleicher Qualität.

AV1-Encodierung ist rechenintensiv und wächst mit Auflösung und Bildzahl. Gemessen (Apple Silicon, arm64):
64x48 mit 10 Bildern in 0,02 s, synthetisches 640x360 mit 30 Bildern in 0,2 s (einfacher Inhalt; echtes Material und
HD/4K sind um ein Vielfaches langsamer). Die App sollte Fortschritt und Abbruch anbieten (ABI hat dafür keinen Rückruf).

## Build

`scripts/build-codec.sh av1`. Braucht `cmake` und `ninja` im PATH und die Xcode Command Line Tools, kein nasm.
Universal (arm64 + x86_64), macOS 14, libaom 3.15.3 (Release-Tarball, SHA-256 in `UPSTREAM`) statisch, nur Encoder
(Decoder, Tests, Beispiele, Tools, Doku aus). x86_64 baut mit dem generischen C-Target (ohne SIMD, deutlich langsamer auf Intel-Macs).
`VERSION` ist die libaom-Version.

## Lizenzen

`LICENSE-libaom` (BSD-2) mit `PATENTS-libaom` (Patent-Grant). Der Muxer in `dsc_av1.c` ist eigener Code.
