# dummy

Test-Codec für die Build-Pipeline (`scripts/build-codec.sh dummy`). Wird nicht ausgeliefert.

## ABI (C, Version 1)

Jede Codec-Dylib exportiert:

```c
int32_t dsc_api_version(void);
int32_t dsc_convert(const char *src, const char *dst, const char *targetExt);
```

- `dsc_api_version`: gibt die ABI-Version zurück (aktuell 1). Die App lehnt andere Werte ab.
- `dsc_convert`: wandelt die Datei `src` (Pfad, UTF-8) in `dst` (Pfad, UTF-8) um.
  `targetExt` ist die Zielendung ohne Punkt, z. B. `"jxl"`.
- Rückgabe: `0` = Erfolg, jeder andere Wert = Fehler (Dummy: 1 = src nicht lesbar,
  2 = dst nicht schreibbar, 3 = Schreibfehler). `dst` darf bei Fehler unvollständig sein.

Der Dummy kopiert nur `src` nach `dst`.

## Ordner je Codec

`build.sh <ausgabe.dylib>` (Build-Schritt), `VERSION`, Quellen, Lizenzdatei (bei echten Codecs).
