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

## Phase 9 – Dropover-Feinschliff
> *Aus Nutzer-Feedback vom 2026-11-19, Referenz: Dropover 5.4.*
> Ist-Stand (aus dem Code): Beim Aufklappen (`shelf.$expanded`-Sink im `ShelfPanel`-Init) wird `frame.origin.y` so angepasst, dass die **obere linke Ecke** fix bleibt, und `animator().setFrame` wächst das Fenster nur nach rechts/unten. Die Pop-Animation besteht aus `Motion.pop` (`.bouncy(duration: 0.4, extraBounce: 0.05)`) in `ShelfPanel.popIn()`/`animateOut(_:)` über `shelf.appeared`/`shelf.closing` und dem `scaleEffect` in `ShelfView`. Menü: `MenuBarExtra` in `DropShelfApp` mit „Neue Ablage“, „Verlauf…“, „Einstellungen…“, „Beenden“. Einstellungen: `TabView` mit Allgemein, Aktionen, Kürzel, Aussehen, Berechtigungen, Über.

### 9a – Großes Fenster wächst aus der Mitte
> Das große Fenster (Detail-Ansicht Raster/Liste, `ShelfPanel.detailSize` 420×360) soll aus seiner **Mitte** in alle Richtungen wachsen und beim Zurückklappen wieder zur Mitte schrumpfen – nicht mehr nach rechts/unten.
> - Im `expandSub`-Sink von `ShelfPanel`: Statt „obere Kante bleibt“ den Mittelpunkt festhalten: `let c = CGPoint(x: frame.midX, y: frame.midY)`, neuer Rahmen `NSRect(x: c.x - size.width/2, y: c.y - size.height/2, width: size.width, height: size.height)`, danach `clamped(_:)` (bleibt im sichtbaren Bildschirm, Aktionsleiste mitgerechnet). Gilt identisch fürs Zurückklappen.
> - Animation: behalte `NSAnimationContext` + `animator().setFrame(_, display: true)` (0,28 s, Kurve `0.2, 0.9, 0.3, 1`) für Fenster **und** `actions` (`actionsFrame(for:)`), da der Rahmen sich ohnehin ändern muss. Zusätzlich im SwiftUI-Inhalt (`ShelfView`) beim Wechsel `detail` einen `.scaleEffect` mit `anchor: .center` von ca. 0,92 → 1 mit `Motion.smooth` einblenden, damit sich der Inhalt nicht „nachzieht“.
> - Bei ausgeschalteten Animationen oder „Bewegung reduzieren“ (`Motion.userOn` / `Motion.enabled`): direkt `setFrame` ohne Animation, nur Mittelpunkt erhalten.
> - Nach dem Aufklappen `invalidateShadow()` (läuft schon über `windowDidResize`), `ShelfManager.shared.save()` speichert die neue Position.
> - Danach bauen (`xcodebuild`), starten (`-DebugSeed a:b -DebugDetail YES`), Screenshot mit `screencapture -l <windowID>` vor und nach dem Aufklappen, prüfen: Mittelpunkt identisch, Fenster nicht vom Bildschirmrand abgeschnitten.

### 9b – Blob-Animation auch für die kleine Ablage
> Die „Blob“-Pop-Animation (`Motion.pop` + `popIn()`/`animateOut(_:)` + `scaleEffect` in `ShelfView`) soll für die kleine Ablage genauso gelten: beim Öffnen, Schließen und beim Wechsel klein ↔ groß.
> - Keine Doppelung: Erstelle in `Glass.swift` **einen** wiederverwendbaren Modifier `popScale(shown:closing:)` (Skalierung 0,85 → 1 beim Öffnen, 1 → 0,9 beim Schließen, `anchor: .center`, Deckkraft, `Motion.pop`) und ersetze damit den bisherigen Inline-`scaleEffect`/`opacity`-Block in `ShelfView`. Nutze ihn auch für die kleine und die große Ansicht (`topBar`/`content` bzw. `DetailView`).
> - Beim Wechsel klein ↔ groß: Inhalt blobbt kurz mit (Skalierung 0,96 → 1 über `Motion.pop`), Fenster-Rahmen folgt der Mitte-Logik aus 9a; gleiche Federparameter (`Motion.pop`), keine zweite eigene Spring-Definition.
> - `popIn()` wird für jede neue Ablage (auch per Schütteln, Hotkey, Wiederherstellen) aufgerufen; `animateOut(_:)` für Schließen (X, Auto-Schließen, AirDrop-Leeren). `Motion.enabled` beachten: bei „Bewegung reduzieren“ nur kurzer Fade (0,15 s).
> - Danach bauen, starten, Screenshot (`screencapture -l <windowID>`) mitten in der Animation (z. B. 0,1 s nach Start) und im Endzustand, prüfen.
> 
> **Effekt-Referenz (Nutzer-Screenshot):** Beim Öffnen/Schließen der Ablage und beim Ablegen/Herausziehen soll sich der Inhalt wie flüssiges Glas verformen – Genie-artig: Vorschaubilder werden zum Ziel hin gekrümmt und gestreckt (an einer Seite schmal zusammengezogen, an der anderen breit), an den Rändern mit leichter chromatischer Aberration (rot/blau versetzte Kanten). Umsetzung mit SwiftUI-Metal-Shadern (`.distortionEffect` für Krümmung/Streckung, `.layerEffect` für den RGB-Versatz) in einer neuen `Shaders.metal`, gesteuert über einen animierten Fortschritt 0→1 mit der `Motion.pop`-Feder. Shader-Effekte gibt es erst ab macOS 14: hinter `if #available(macOS 14, *)` kapseln; auf macOS 13 und bei „Bewegung reduzieren“ auf das bestehende `Motion.pop`-Skalieren zurückfallen. Dezent halten (max. ~0,25–0,4 s, Aberration nur 1–3 px), abschaltbar über die vorhandene Einstellung `animationsEnabled`.

### 9c – Einstellungen und Menü im Stil von Dropover
> **Einstellungsfenster (`SettingsView.swift`):** Ersetze den `TabView` durch ein Layout wie Systemeinstellungen / Dropover 5.4: links eine Seitenleiste (feste Breite ~210 pt, `List` mit `.listStyle(.sidebar)` in `NavigationSplitView` oder `HStack`), rechts der Detailbereich. Auswahl weiterhin in `@AppStorage("settingsTab")`.
> - Seitenleisten-Einträge mit runden farbigen Quadraten (24×24, `RoundedRectangle(cornerRadius: 6, style: .continuous)` in Farbe, weißes SF Symbol 13 pt `.semibold`) und Titel: **Fensteraktivierung** (`hand.draw`, blau), **Fensterinteraktionen** (`rectangle.on.rectangle`, grün), **Allgemein** (`gearshape`, grau), **Aussehen** (`paintbrush`, violett), **Aktionen** (`square.grid.2x2`, orange), **Berechtigungen** (`lock.shield`, rot), **Über** (`info.circle`, grau). Unten in der Seitenleiste: App-Symbol (32 pt) + „DropShelf“ + Version (`CFBundleShortVersionString`) in grau.
> - Rechts: großer fetter Titel (`.system(size: 24, weight: .bold)`), darunter eine graue einzeilige Beschreibung, dann gruppierte Karten: `VStack(spacing: 0)` mit `.background(.quaternary, in: RoundedRectangle(cornerRadius: 11, style: .continuous))`, Zeilen mit kleinem Symbol links, Titel (13 pt), grauem Untertitel (11 pt `.secondary`) und Bedienelement rechts (`Toggle` `.switch`, `Picker`, `Slider`, Rekorder), Trennlinien dazwischen (`Divider` mit Einzug). Baue dafür kleine wiederverwendbare Views `SettingsCard`, `SettingsRow` und `SidebarIcon` – keine Kopien pro Tab. Das Fenster ist ~720×520 pt, Inhalt scrollt.
> - **Alle bestehenden Einstellungen bleiben erhalten, nichts geht verloren.** Zuordnung:
>   - *Fensteraktivierung:* `shakeEnabled` („Schütteln beim Ziehen“) + `shakeSensitivity` (Slider niedrig–hoch), Tastenkürzel mit Rekorder und An/Aus (`hotkeyShelfEnabled` Neue Ablage, `hotkeyAirDropEnabled`, `hotkeyHistoryEnabled`; bestehende Rekorder-Zeilen aus `ShortcutsTab` übernehmen), „Standardposition für neue Fenster“ (Picker: An der Maus / Zuletzt verwendet – nur wenn die bestehende Logik in `ShelfManager.newShelf()` das schon hergibt, sonst „An der Maus“ fest anzeigen). **NEU (nur falls machbar, klar so kennzeichnen):** „Mit Modifikatortaste aktivieren“ (Picker ⇧/⌥/⌃/⌘/Aus, `@AppStorage("shakeModifier")`): Beim Ziehen mit gehaltener Taste (`NSEvent.modifierFlags` im globalen `.leftMouseDragged`-Monitor von `ShakeDetector.handle`) öffnet sich die Ablage sofort ohne Schütteln. Wenn das den Detektor unverhältnismäßig verkompliziert, weglassen und im Bericht erwähnen.
>   - *Fensterinteraktionen:* `autoCloseWhenEmpty`, `askClearAfterAirDrop`, `viewMode` (Standard-Ansicht Raster/Liste), Verlauf (`historyEnabled`, `historyLimit`). Kopieren-vs-Verschieben/Herausziehen-Verhalten nur als Zeile aufnehmen, wenn es eine bestehende Einstellung dafür gibt; sonst nicht erfinden.
>   - *Allgemein:* Start beim Anmelden (`SMAppService`), `openShelfOnLaunch`.
>   - *Aussehen:* Liquid Glass / Glas-Intensität (`glassIntensity`, Slider „klar ↔ dunkel“), `animationsEnabled`, Hinweis auf „Bewegung reduzieren“.
>   - *Aktionen:* bisherige Aktionsliste aus `ActionsTab` (Quick Look, ZIP, Teilen, Im Finder zeigen, Pfade kopieren, AirDrop …) mit den bestehenden Schaltern.
>   - *Berechtigungen* und *Über:* bisheriger Inhalt, nur im neuen Karten-Stil.
>
> **Menüleistenmenü (`DropShelfApp.swift`):** Aufbau wie Dropover:
> 1. „Neue Ablage“ mit angezeigtem Kürzel **⌃⌥Space** (`ShelfManager.shared.newShelf()`).
> 2. **NEU:** „Ablage aus der Zwischenablage“ mit Kürzel (Vorschlag ⌃⌥V, über `HotKey.swift` wie die anderen registrieren, ID und Menüeintrag): legt eine neue Ablage an und füllt sie aus `NSPasteboard.general` – nutze die vorhandene Drop-Logik `Shelf.drop`/`Shelf.add` bzw. lies `readObjects(forClasses: [NSURL.self, NSImage.self, NSString.self])`; leere Zwischenablage → kurzer Hinweis/Piepton, keine leere Ablage.
> 3. Abschnitt **„Vorherige Ablagen“** (graue Überschrift): die letzten 3 Einträge aus `HistoryStore.shared.entries.prefix(3)` mit kleinem Vorschaubild (erste Datei, 24 pt, `NSWorkspace.shared.icon(forFile:)` bzw. QL-Thumbnail), `Entry.title` und relativer Zeit („Heute, 16:31“ – `DateFormatter` mit `doesRelativeDateFormatting = true`, `dateStyle: .short`, `timeStyle: .short`). Klick stellt die Ablage wieder her (die bisher `private` Logik `HistoryPanel.restore(_:)` in eine gemeinsame, nicht private Funktion ziehen und von beiden nutzen, nichts duplizieren). Nur anzeigen, wenn `HistoryStore.enabled` und Einträge vorhanden.
> 4. „Alle Ablagen ›“ (öffnet `HistoryPanel.toggle()`; als Untermenü nur, falls es im gewählten Stil sauber geht).
> 5. Trennlinie, Versionszeile in grau („DropShelf 1.0“, deaktiviert), „Über DropShelf…“ (`NSApp.orderFrontStandardAboutPanel` oder Tab Über), „Einstellungen…“ **⌘,**, Trennlinie, „DropShelf beenden“ **⌘Q**.
> - **Stil-Entscheidung:** `.menuBarExtraStyle(.menu)` (natives `NSMenu`) zeigt Bilder in `Button`-Labels (`Label(title, nsImage)`/`Image(nsImage:)`) an und liefert Kürzel/Disabled-Zeilen/Untermenüs wie Dropover – **nimm `.menu`**. `.window` nur, wenn Vorschaubilder im Menü nicht klein genug oder nicht darstellbar sind; dann Fensterstil mit eigenen Zeilen. Kürzel im Menü per `.keyboardShortcut` anzeigen, die globalen Hotkeys laufen weiter über Carbon (`HotKey.swift`).
> - Danach bauen, starten (`-DebugOpenHistory YES` legt Testverlauf an, `-DebugOpenSettings YES` öffnet die Einstellungen, `-settingsTab` pro Bereich), Screenshot der Einstellungen jedes Bereichs und des geöffneten Menüs mit `screencapture -l <windowID>` bzw. `screencapture -R`, prüfen, dass jede alte Einstellung noch erreichbar ist.

## Phase 10 – Glas mit Inhalt, AirDrop-Symbol, flüssiges Aufklappen, Leistung
> *Aus Nutzer-Feedback vom 2026-11-20 (Screenshot):* Die leere Ablage zeigt das klare, lichtbrechende Glas wie Canopy – „wenn eine Datei drin liegt, wird es wieder so“: Mit Datei (PDF-Vorschau + Kapsel „PP1_Test…lage 2.pdf ›“) sieht die Ablage wieder wie mattes, verschwommenes graues System-Glas aus, ohne Linse/Lichtbrechung. Ebenso die runden Aktionsknöpfe darunter.
>
> 1. **Glas mit Inhalt:** Finde die **Ursache**, warum die Lichtbrechung (`GlassKit.refract`, privater `glassBackground`-Filter, Werte erst nach `l.filters = l.filters` aktiv) verschwindet, sobald Dateien in der Ablage liegen. Kandidaten: SwiftUI-Inhaltswechsel baut `NSGlassEffectView`/`CABackdropLayer` neu auf und die Filterwerte werden ohne erneutes `refract` zurückgesetzt; die Ablage wird beim Ablegen Schlüsselfenster und das Glas sieht dann anders aus; Vorschau/Kapsel/`DragOutView` bringen eigenes Material/Blur mit; die Suche nach der „größten `glassBackground`-Ebene“ trifft eine andere Ebene, sobald Kapsel/Knöpfe eigene Glas-Ebenen haben; die dunkle Tönung in der Mitte wächst. Beheben, sodass das eingestellte Glas mit 0, 1 und vielen Dateien, klein und groß, Schlüsselfenster oder nicht, **identisch** aussieht. Prüfen mit Ausschnitts-Screenshots über buntem Testhintergrund (leer vs. mit PDF).
> 2. **AirDrop-Symbol:** Der AirDrop-Knopf zeigt ein WLAN-/Funkwellen-Symbol. Stattdessen das echte AirDrop-Symbol: bevorzugt `NSSharingService(named: .sendViaAirDrop)?.image` als Vorlage (Template) in Weiß (~80 % wie die anderen Knöpfe); ist das Bild ungeeignet (farbig/groß), ein SF-Symbol für AirDrop auf macOS 26/27 suchen (z. B. `NSImage(systemSymbolName: "airdrop", …)`, auf nicht-nil prüfen), sonst das bisherige Symbol. Auch in der Aktionsliste der Einstellungen und im Menü verwenden.
> 3. **Dateien direkt auf den AirDrop-Knopf ziehen** muss wirklich funktionieren: echt testen (kleines Hilfsprogramm, das per `CGEvent` eine Datei aus dem Finder bzw. von der Ablage auf den AirDrop-Knopf zieht; ohne Bedienungshilfen-Recht ersatzweise ein Debug-Pfad, der den Drop-Delegate mit `NSItemProvider`s aufruft). Sicherstellen: Die Aktionsleiste erscheint während eines Drags aus dem Finder, sobald der Drag das Ablage-Fenster betritt (auch ohne vorheriges Hovern) und bleibt beim Weiterziehen nach unten zu den Knöpfen; das Drop-Ziel des Knopfs wird getroffen (Kindfenster ignoriert Mausereignisse während des Drags nicht); `NSSharingService(.sendViaAirDrop).perform(withItems:)` bekommt die URLs (AirDrop-Fenster öffnet sich).
> 4. **Aufklappen flüssiger („weniger Lags“):** Übergang klein ↔ groß erst messen (`sample`, Bildzählung einer `screencapture -v`-Aufnahme, ggf. `xctrace` „Animation Hitches“), dann beheben: Kosten wie `animator().setFrame` bei gleichzeitigem SwiftUI-Neu-Layout jedes Frames, `NSGlassEffectView`-Neuzeichnen + `refract` bei jedem Resize-Schritt, neu erzeugte Vorschaubilder (`QLThumbnailGenerator`) während der Animation, Lösen/Anhängen des Kindfensters. Ziel: sichtbar flüssig bei 60/120 Hz, keine Hänger.
> 5. **Energiebericht:** CPU/Speicher/Energie (`top … -stats pid,cpu,mem,idlew,power`, `ps -o rss,%cpu`) im Leerlauf ohne Ablage, mit offener Ablage, bei Hover/Animationen, beim Ziehen/Schüttel-Monitor und in der großen Ansicht mit ~10 Dateien. Alles über ~1 % CPU im Leerlauf beheben (Timer, Dauer-Animationen, globale Monitore, wiederholtes `refract`).
