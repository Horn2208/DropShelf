# DropShelf – Prompt-Plan

macOS-App für eine schwebende Ablage (ähnlich wie Dropover, aber selbst gebaut): Dateien in eine Ablage ziehen, dort sammeln und später weiterziehen oder **direkt per AirDrop senden**.

**Stack:** Swift 6, SwiftUI und AppKit (`NSPanel`), macOS 13+, keine Fremd-Bibliotheken.
**Ablauf:** Jede Phase ist ein eigener Prompt an Claude Code. Erst bauen und testen, dann die nächste Phase.

---

## Phase 1 – Grundgerüst
> Erstelle in diesem Ordner ein macOS-App-Projekt „DropShelf“ (SwiftUI, Swift 6, Deployment Target macOS 13). Lege den Xcode-Projektrahmen mit XcodeGen (`project.yml`) an oder direkt als `.xcodeproj`. Die App erscheint als Symbol in der Menüleiste (`MenuBarExtra`), ohne Dock-Symbol (`LSUIElement`). Im Menü: „Neue Ablage“ und „Beenden“. App-Sandbox aktivieren mit den Entitlements `files.user-selected.read-write` und `files.bookmarks.app-scope`. Baue mit `xcodebuild` und stelle sicher, dass der Build ohne Fehler durchläuft.

## Phase 2 – Schwebende Ablage
> Baue das Ablage-Fenster: ein `NSPanel` (`.nonactivatingPanel`, Ebene `.floating`, auf allen Spaces sichtbar), etwa 200×220 Punkte groß, mit abgerundeten Ecken und Material-Hintergrund. Es lässt sich verschieben und hat einen Schließen-Knopf. Die Ablage nimmt Dateien, Bilder, Text und URLs per Drop an (`onDrop`/`NSItemProvider`) und zeigt sie als gestapelte Vorschaubilder (`QLThumbnailGenerator`) mit Zähler. Text und Bilder ohne Datei werden als temporäre Dateien in `~/Library/Caches/DropShelf` gespeichert. Abgelegte Dateien werden als Security-Scoped Bookmarks gespeichert (`bookmarkData(options: .withSecurityScope)`, Zugriff mit `startAccessingSecurityScopedResource()`), damit die Ablage auch nach einem Neustart der App wieder geladen wird. Veraltete Lesezeichen werden erneuert, fehlende Dateien entfernt.

## Phase 3 – Herausziehen
> Man kann Dateien wieder aus der Ablage ziehen, entweder alle als Stapel oder einzeln über eine aufklappbare Liste. Nutze `NSDraggingSource` mit mehreren `NSPasteboardItem`s. Mit gedrückter Wahltaste wird kopiert statt verschoben. Ist die Ablage nach dem Herausziehen leer, schließt sie sich von selbst (lässt sich in den Einstellungen abschalten).

## Phase 4 – AirDrop ⭐
> Füge der Ablage einen AirDrop-Knopf hinzu. Ein Klick sendet alle Dateien der Ablage per
> `NSSharingService(named: .sendViaAirDrop)` mit `perform(withItems: urls)`. Vorher wird `canPerform(withItems:)` geprüft; ist AirDrop nicht verfügbar, ist der Knopf ausgegraut und zeigt einen Tooltip mit dem Grund.
> In der Einzelansicht gibt es zusätzlich das Kontextmenü „Per AirDrop senden“ für eine einzelne Datei.
> Nutze den `NSSharingServiceDelegate`: Nach erfolgreichem Senden erscheint optional die Rückfrage „Ablage leeren?“, bei einem Fehler eine kurze Meldung.
> Füge außerdem ein globales Tastenkürzel hinzu (Standard ⌃⌥A), das die zuletzt aktive Ablage per AirDrop sendet. Registriere es über Carbon `RegisterEventHotKey` mit `InstallEventHandler` (funktioniert in der Sandbox und ohne Bedienungshilfen-Berechtigung) und gib es beim Beenden wieder frei.
> Teste das Ganze von Hand mit einem iPhone in der Nähe.

## Phase 5 – Ablage beim Schütteln öffnen
> Wenn man beim Ziehen einer Datei die Maus schüttelt (mehrere schnelle Richtungswechsel innerhalb von ca. 0,5 s), öffnet sich an der Mausposition eine neue Ablage. Erkenne das über einen globalen `NSEvent`-Monitor für `.leftMouseDragged`. Die Empfindlichkeit lässt sich in den Einstellungen anpassen. Benötigte Berechtigungen fragt die App mit einer verständlichen Erklärung ab.

## Phase 6 – Weitere Aktionen
> Füge der Ablage ein Aktionsmenü hinzu: Quick-Look-Vorschau (Leertaste), „Teilen…“ (`NSSharingServicePicker`), „Als ZIP komprimieren“ (`/usr/bin/ditto -c -k`), „Im Finder zeigen“ und „Pfade kopieren“.

## Phase 7 – Einstellungen und Feinschliff
> Baue ein Einstellungsfenster (`Settings`-Szene, Werte per `@AppStorage`) für Schüttel-Empfindlichkeit, Tastenkürzel, automatisches Schließen, Rückfrage nach AirDrop und Start bei der Anmeldung (`SMAppService`). Ergänze Animationen beim Ablegen und Entfernen sowie die Unterstützung für „Bewegung reduzieren“. Am Ende: Release-Build, App-Symbol, README.

---

**Später, wenn gebraucht:** mehrere gleichzeitige Ablagen mit eigenem Verlauf, Upload in die Cloud, Sync per iCloud.
