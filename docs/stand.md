# Stand: Sparkle 2 für DropShelf

Stand: 2026-11-27. Plan und Schritte stehen in [plan.md](plan.md).

## Erledigt

- **Projektregel gelockert:** In `PLAN.md` (Kopfbereich und Abschnitt „Rahmen“) steht die Ausnahme für Sparkle 2 mit Begründung. Die Änderung ist nur lokal, nicht committet.
- **Signatur geprüft:** Ein Zertifikat „Developer ID Application“ mit Team-ID B892A3M49U ist lokal vorhanden.
- **Notar-Profil geprüft:** `DropShelf-Notar` ist eingerichtet. Der Verlauf ist abrufbar.
- **Dokumentation:** `docs/sparkle-update.md` (Vorlage für diesen Stand), `docs/plan.md`, `docs/stand.md`. Alle nur lokal.

## Noch nicht umgesetzt

- Sparkle-Paket in `project.yml`: nicht begonnen.
- `project.pbxproj` gesichert: nicht verifiziert. Die Sicherung war im Auftrag an den Agenten, der gestoppt wurde.
- `Info.plist`: keine Sparkle-Schlüssel.
- `Sources/UpdateCheck.swift`: unverändert.
- Sandbox-Entitlements: unverändert.
- Release-Skript, Appcast und ZIP-Asset: nicht begonnen.
- Hardened Runtime: `ENABLE_HARDENED_RUNTIME = NO`, unverändert.

## Hinweise zum Repo

- `PLAN.md` und `DropShelf.xcodeproj/project.pbxproj` enthalten fremde uncommittete Änderungen. Vor einem Commit trennen.
- Die Datei `docs/sparkle-update.md` ist teilweise Vorläufer von `docs/plan.md` und `docs/stand.md`. Sie kann später gelöscht werden.
- Nichts committet, nichts gepusht, kein Release.
