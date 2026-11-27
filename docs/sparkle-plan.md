# Plan: Sparkle 2 für DropShelf

Stand: 2026-11-27. Was schon erledigt ist, steht in [stand.md](stand.md).

## Ziel

Der Update-Knopf aktualisiert DropShelf selbst, ohne dass man neu installieren muss.

## Entscheidungen

- **Framework:** Sparkle 2 über Swift Package Manager. Die Projektregel „keine Fremd-Bibliotheken“ ist für Sparkle als einzige Ausnahme gelockert.
- **Signatur:** Developer ID Application, Team-ID B892A3M49U. Notar-Profil `DropShelf-Notar`.
- **Update-Quelle:** `appcast.xml` im Repo, ausgeliefert über raw.githubusercontent.com auf `main`.
- **Release-Assets pro Version:** `DropShelf-<version>.dmg` (Erstinstallation) und `DropShelf-<version>.zip` (In-App-Update, notarisiert und gestapelt).
- **Schlüssel:** EdDSA. Der öffentliche Schlüssel steht in der `Info.plist`, der private Schlüssel bleibt im Schlüsselbund.

## Schritte

1. **Sicherung:** `project.pbxproj` sichern, bevor XcodeGen läuft. Die Datei hat uncommittete Änderungen aus anderer Arbeit.
2. **Paket:** Sparkle 2 in `project.yml` für das DropShelf-App-Target eintragen, dann XcodeGen laufen lassen.
3. **Diff prüfen:** `project.pbxproj` gegen die Sicherung vergleichen. Fremde Änderungen müssen erhalten sein.
4. **Info.plist:** `SUFeedURL`, `SUPublicEDKey` (per `generate_keys`), `SUEnableAutomaticChecks`.
5. **Update-Logik:** `Sources/UpdateCheck.swift` auf Sparkle umstellen. Der Update-Knopf in `SettingsView.swift` (`updateGroup`) ruft den Updater auf. Tests in `Tests/UpdateCheckTests.swift` anpassen.
6. **Sandbox:** Entitlements für Sparkles XPC-Dienste prüfen (mach-lookup mit `-spks` und `-spki`).
7. **Build:** ein `xcodebuild build` zur Kompilierprüfung, ohne Start der App.
8. **Release-Skript:** ZIP erzeugen, Appcast erzeugen und signieren, Assets beim GitHub-Release hochladen.
9. **Notarisierung:** Hardened Runtime aktivieren und das ZIP notarisieren. Dafür ist `ENABLE_HARDENED_RUNTIME` nötig, derzeit `NO`.
10. **Test:** Update am echten Update-Knopf testen, ohne eigenen Test-Build.

## Regeln

- Nur von `main` releasen. Entwicklungsbranches nicht pushen.
- Keine eigenen Test-Builds für den Nutzer. Tests über den Update-Knopf, nicht doppelt laufen lassen.
- Vor Codeänderungen `graphify query`, danach `graphify update .`.
