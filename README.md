# DropShelf

DropShelf ist eine kleine macOS-Menüleisten-App: eine schwebende Ablage, auf der du Dateien, Bilder, Text und Links kurz zwischenlagerst, um sie von dort aus woanders wieder abzulegen oder zu verschicken.

## Funktionen

- **Schwebende Ablage** im Glas-Look, auf allen Spaces sichtbar, frei verschiebbar
- **Hineinziehen und Herausziehen** von Dateien, Bildern, Text und URLs (einzeln oder als Stapel, mit Wahltaste kopieren)
- **Senden**: AirDrop, Nachrichten, Mail und Teilen…
- **Aktionen**: Quick Look (Leertaste), als ZIP komprimieren, im Finder zeigen, Pfade kopieren
- **Verlauf** früherer Ablagen
- **Schütteln zum Öffnen**: Maus beim Ziehen einer Datei schütteln, dann öffnet sich eine Ablage an der Mausposition
- **Einstellungen**: automatisches Schließen, Rückfrage „Ablage leeren?“ nach AirDrop, Glas-Intensität, Animationen („Bewegung reduzieren“ wird beachtet), Start bei der Anmeldung

## Tastenkürzel

| Aktion | Standard | 
|---|---|
| Neue Ablage an der Maus | ⌃⌥Space |
| Aktive Ablage per AirDrop senden | ⌃⌥A |
| Verlauf öffnen | ⌃⌥V |

Alle Kürzel lassen sich unter Einstellungen › Kürzel neu aufnehmen (mindestens ⌃, ⌥ oder ⌘) oder abschalten.

## Voraussetzungen

- macOS 13 oder neuer
- Xcode (Swift 6) und [XcodeGen](https://github.com/yonaskolb/XcodeGen) zum Bauen

## Bauen

```sh
xcodegen
xcodebuild -project DropShelf.xcodeproj -scheme DropShelf -configuration Release -derivedDataPath build build
```

Die App liegt danach in `build/Build/Products/Release/DropShelf.app`. Für zuverlässigen Start bei der Anmeldung die App nach `/Applications` kopieren. Das Symbol lässt sich mit `swift scripts/make-icon.swift` neu erzeugen.

## Berechtigungen

- **Bedienungshilfen**: nur für die Schüttel-Erkennung (liest ausschließlich die Mausbewegung). Ohne sie funktioniert alles andere.
- Tastenkürzel brauchen keine Berechtigung.

## Sandbox

DropShelf läuft in der App-Sandbox. Dateizugriff erfolgt über vom Nutzer abgelegte Dateien und Security-Scoped Bookmarks, damit Ablagen nach einem Neustart erhalten bleiben. Es gibt keine Netzwerkzugriffe und keine Fremdbibliotheken.
