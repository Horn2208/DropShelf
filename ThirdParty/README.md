# ThirdParty

Statisch eingebundene C-Encoder-Bibliotheken für DropShelf.

## Aufbau

- `DropShelfCodecs/` – Lokales SwiftPM-Paket (ohne Netzwerk-Abhängigkeiten), eingebunden über `project.yml` in die Targets `DropShelf`, `DropShelf Troll`, `DropShelf Troll kurz` und `DropShelfTests`.
- Jede C-Bibliothek erhält ein eigenes C-Target unter `DropShelfCodecs/Sources/C<Name>/` samt eigenem `include/`-Ordner und Original-Lizenzdatei.
- Der Swift-Wrapper `DropShelfCodecs` kapselt die C-APIs typsicher und Swift-6-konform (`Sendable`), sodass der übrige App-Code keine C-Pointer oder C-Header-Konflikte sieht.
- Keine Kindprozesse, kein Nachladen zur Laufzeit, kompatibel mit App-Sandbox sowie Apple Silicon (`arm64`) und Intel (`x86_64`).

Lizenzübersicht und Quellen siehe [`../THIRD-PARTY-LICENSES.md`](../THIRD-PARTY-LICENSES.md).
