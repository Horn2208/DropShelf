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

## Phase 5 – Ruhigeres Design + Erreichbarkeit
> Überarbeite die Optik der Ablage: ruhiger, aufgeräumter, nativ wie macOS. Funktionen nicht ändern, nur Darstellung und Bedienung.
>
> **Problem zuerst:** Das Menüleisten-Symbol ist auf vollen Menüleisten (Notch, Bartender/Ice) oft unsichtbar. Daher:
> - Beim App-Start, wenn keine Ablage wiederhergestellt wird, direkt eine leere Ablage öffnen (abschaltbar per UserDefaults `openShelfOnLaunch`, Default true).
> - Globales Tastenkürzel ⌃⌥Space (Carbon, wie der AirDrop-Hotkey in `HotKey.swift`) öffnet eine neue Ablage an der Mausposition.
> - Erneutes Öffnen der App (Doppelklick im Finder, `applicationShouldHandleReopen`) öffnet ebenfalls eine Ablage.
>
> **Fenster:**
> - Etwas größer (ca. 220×250), große Eckenradien (~26 pt, `.continuous`) – auch das Panel selbst/die Schattenform rund, keine eckigen Ränder sichtbar. Hintergrund: **Grau bleibt wie es ist (nicht heller machen), stattdessen mehr Glas-Look** – `NSVisualEffectView` (`.hudWindow`, `.behindWindow`, `.active`) als rund maskierter Fensterinhalt (transparentes Panel), darüber nur leichte Grau-Tönung, oben dezenter Glanz (Weiß 8 % → 0 % im oberen Drittel), 1-pt-Innenkontur Weiß ~18 % (Hellmodus Schwarz ~12 %), weicher Schatten.
> - Oben mittig ein kleiner Griff (36×5 pt, Kapsel, Weiß ~25 %) als Hinweis zum Verschieben.
> - **Verschieben:** Das Fenster lässt sich zuverlässig verschieben – am Griff, an jedem freien Hintergrundbereich und an der Leer-Ansicht. Umsetzung: eigene kleine NSView für diese Bereiche, die in `mouseDown` `window?.performDrag(with: event)` aufruft (nicht nur `isMovableByWindowBackground`, da SwiftUI-/NSHostingView-Inhalt die Ereignisse sonst schluckt). Ziehen auf der Vorschau bzw. den Listenzeilen zieht weiterhin Dateien heraus (bestehende `DragOutView`), Knöpfe bleiben klickbar. Fenster bleibt dabei innerhalb des sichtbaren Bildschirms; die neue Position wird wie bisher gespeichert. Mauszeiger über Griff/Hintergrund: `NSCursor.openHand`, beim Ziehen `closedHand`.
> - Oben links ein runder Schließen-Knopf, oben rechts ein runder Aufklapp-Knopf (Chevron). Beide 28 pt, Kreis mit Weiß ~12 % Hintergrund, SF Symbol in Weiß ~80 %, Hover leicht heller.
>
> **Inhalt:**
> - Mitte: Vorschau des Stapels, groß und ruhig – **keine Rotation**, ein einzelnes Dokument gerade; bei mehreren Dateien nur ein dezenter Versatz (2–3 pt). Vorschau gerade, **Ecken 8 pt `.continuous`**, feiner heller Rand (0,5 pt Weiß ~15 %), weicher Schatten; Kapsel (Weiß ~12 %, max. ~170 pt) mit Dateiname bzw. „N Dateien“. Die blaue Zähler-Plakette entfällt komplett.
> - **Unter der Vorschau** (mit 10 pt Abstand, mittig): eine Kapsel mit dem Dateinamen (bei mehreren: „3 Dateien“), abgeschnitten in der Mitte (`truncationMode(.middle)`), mit kleinem Chevron rechts zum Aufklappen. Keine separate Zähler-Badge mehr.
> - Leere Ablage: nur zentriert ein SF Symbol (`tray.and.arrow.down`, hell, groß, dünne Strichstärke) und darunter „Dateien hierher ziehen“ in sekundärer Farbe.
> - Beim Drüberziehen: Kontur wird zur Akzentfarbe, Inhalt skaliert minimal (1,03) mit sanfter Feder; bei „Bewegung reduzieren“ nur Farbwechsel.
>
> **AirDrop & Aktionen als kleine runde Knöpfe:**
> - Unterhalb der Ablage (außerhalb des Fensters, im selben Panel, transparent dahinter) eine Reihe kleiner runder Knöpfe (34 pt, Kreis, Material-Hintergrund, feine Kontur): zuerst **AirDrop** (SF Symbol `airplayaudio` ist falsch – nimm ein passendes, z. B. `dot.radiowaves.up.forward`), dann **Nachrichten**, **Mail** und **Teilen…** (`square.and.arrow.up`, öffnet `NSSharingServicePicker`). Nachrichten/Mail über `NSSharingService(named: .composeMessage / .composeEmail)`.
> - Die Reihe ist nur sichtbar, wenn die Ablage Dateien enthält und die Maus über dem Panel ist (sanft ein-/ausblenden); `.help`-Tooltips für jeden Knopf. Der bisherige AirDrop-Knopf im Fenster entfällt.
> - Nicht verfügbare Dienste ausgegraut (`canPerform`).
>
> **Typografie (Apple-Systemschrift):**
> - Nur SF Pro über die Systemschrift: `.font(.system(size:weight:design: .default))` bzw. Text-Styles. Keine eigenen Fonts einbinden.
> - Dateiname: 13 pt, `.medium`; Hinweistexte: 12 pt, `.regular`, `.secondary`; Listenzeilen: 13 pt `.regular`, Dateigröße/Art 11 pt `.secondary` mit `monospacedDigit()`.
>
> **Aufgeklappte Liste:**
> - Gleicher Stil: Zeilen mit 32-pt-Vorschau, Name, darunter Größe; Hover-Hintergrund Weiß ~6 %, Ecken 8 pt; keine Trennlinien.
>
> **Allgemein:**
> - Farben nur über semantische Systemfarben bzw. Weiß mit Deckkraft; funktioniert im Hell- und Dunkelmodus (im hellen Modus `.popover`-Material und Schwarz statt Weiß für Konturen).
> - Animationen kurz (0,2–0,25 s), Federn ohne Überschwingen; „Bewegung reduzieren“ beachten.
> - Danach bauen, kurz starten, Screenshot des Fensters mit `screencapture -l <windowID>` machen und prüfen, ob alles ruhig und aufgeräumt wirkt.

> **Nachtrag Phase 5:** Glas maximal (transparenteres Material, leichte Tönung, per Einstellung regelbar), Pop-Animationen (Öffnen, Schließen, Ablegen, Aktionsreihe, Hover) und eine Detail-Ansicht (Raster/Liste, Sortierung, Größe • Pixelmaße) ersetzen die alte Liste.

## Phase 6 – Ablage beim Schütteln öffnen
> Wenn man beim Ziehen einer Datei die Maus schüttelt (mehrere schnelle Richtungswechsel innerhalb von ca. 0,5 s), öffnet sich an der Mausposition eine neue Ablage. Erkenne das über einen globalen `NSEvent`-Monitor für `.leftMouseDragged`. Die Empfindlichkeit lässt sich in den Einstellungen anpassen. Benötigte Berechtigungen fragt die App mit einer verständlichen Erklärung ab.

## Phase 7 – Weitere Aktionen
> Füge der Ablage ein Aktionsmenü hinzu: Quick-Look-Vorschau (Leertaste), „Teilen…“ (`NSSharingServicePicker`), „Als ZIP komprimieren“ (`/usr/bin/ditto -c -k`), „Im Finder zeigen“ und „Pfade kopieren“.

## Phase 8 – Einstellungen und Feinschliff
> **Bereits vorgezogen:** Einstellungsfenster inkl. Tabs Allgemein, Kürzel (An/Aus), Aussehen, Berechtigungen (Status-Übersicht) und Über. Offen: Schüttel-Empfindlichkeit, Kürzel-Rekorder, Release/Icon/README.
>
> **Phase 8 erledigt:** Kürzel-Rekorder, Start bei Anmeldung, Auto-Schließen/AirDrop-Rückfrage/Schüttel-Empfindlichkeit, Bewegung reduzieren, App-Symbol (`scripts/make-icon.swift`), README, Release-Build.
>
> Baue ein Einstellungsfenster (`Settings`-Szene, Werte per `@AppStorage`) für Schüttel-Empfindlichkeit, Tastenkürzel, automatisches Schließen, Rückfrage nach AirDrop und Start bei der Anmeldung (`SMAppService`). Ergänze Animationen beim Ablegen und Entfernen sowie die Unterstützung für „Bewegung reduzieren“. Am Ende: Release-Build, App-Symbol, README.

---

**Später, wenn gebraucht:** mehrere gleichzeitige Ablagen mit eigenem Verlauf, Upload in die Cloud, Sync per iCloud.
