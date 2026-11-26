import AppKit
import UniformTypeIdentifiers

/// Lädt JSON-Listen, ohne wegen einzelner kaputter Einträge Daten zu verlieren.
enum PersistedList {
    /// Ersatz für ein fehlendes Datum: alt genug, um beim Kürzen keine datierten Einträge zu verdrängen.
    static let unknownDate = Date(timeIntervalSince1970: 0)

    private struct Slot<T: Decodable>: Decodable {
        let value: T?
        init(from decoder: Decoder) { value = try? T(from: decoder) }
    }

    /// Dekodiert pro Element; nil = gar kein JSON-Array, `complete` = kein Eintrag verworfen.
    static func decode<T: Decodable>(_ data: Data) -> (items: [T], complete: Bool)? {
        guard let slots = try? JSONDecoder().decode([Slot<T>?].self, from: data) else { return nil }
        let items = slots.compactMap { $0?.value }
        return (items, items.count == slots.count)
    }

    /// Fehlende Datei = leere Liste. Lesefehler oder fehlgeschlagene Sicherung: `writable` false, Datei nicht überschreiben.
    /// Unlesbarer Inhalt oder verworfene Einträge: Originalbytes landen vorher in `<datei>.corrupt[.n]`.
    /// `keepBackup: false` (Zwischenablage, kann Passwörter enthalten): nie eine Kopie; kein JSON-Array = nicht überschreiben.
    static func load<T: Decodable>(_ url: URL, keepBackup: Bool = true) -> (items: [T], writable: Bool) {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch CocoaError.fileReadNoSuchFile { return ([], true) }
        catch { return ([], false) }
        let decoded: (items: [T], complete: Bool)? = decode(data)
        if let decoded, decoded.complete { return (decoded.items, true) }
        guard keepBackup else { return (decoded?.items ?? [], decoded != nil) }
        return (decoded?.items ?? [], backup(data, of: url))
    }

    static func hasBackup(of url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path + ".corrupt") }

    private static func backup(_ data: Data, of url: URL) -> Bool {
        for n in 0..<1000 {
            let target = URL(fileURLWithPath: url.path + ".corrupt" + (n == 0 ? "" : ".\(n)"))
            if (try? Data(contentsOf: target)) == data { return true }  // dieselben Bytes sind schon gesichert
            do { try data.write(to: target, options: .withoutOverwriting); return true }
            catch CocoaError.fileWriteFileExists { continue }
            catch { return false }
        }
        return false
    }
}

/// Speicherformat einer offenen Ablage.
struct ShelfRecord: Codable, Equatable {
    var id: UUID
    var origin: CGPoint
    var bookmarks: [Data]

    static func encode(_ records: [ShelfRecord]) throws -> Data { try JSONEncoder().encode(records) }
    static func decode(_ data: Data) -> [ShelfRecord] { PersistedList.decode(data)?.items ?? [] }

    /// Einfacher Self-Check (nur Debug, beim Start).
    static func selfCheck() {
        let r = ShelfRecord(id: UUID(), origin: CGPoint(x: 10, y: 20), bookmarks: [Data([1, 2, 3])])
        assert((try? decode(encode([r]))) == [r], "ShelfRecord roundtrip")
        assert(decode(Data("kaputt".utf8)).isEmpty, "ShelfRecord decode garbage")
    }
}

extension ShelfRecord {
    /// Altes Schema: `id` und `origin` haben Ersatzwerte, `bookmarks` sind der Inhalt und bleiben Pflicht.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        origin = try c.decodeIfPresent(CGPoint.self, forKey: .origin) ?? .zero
        bookmarks = try c.decode([Data].self, forKey: .bookmarks)
    }
}

@MainActor
final class Shelf: ObservableObject, Identifiable {
    struct Item: Identifiable {
        var id = UUID()  // var: `replaceURLs` behält die ID über `Item(id:url:bookmark:)`
        let url: URL
        var bookmark: Data?
    }

    let id: UUID
    @Published private(set) var items: [Item] = []
    @Published var expanded = false
    @Published var selection = Selection()  // Finder-Auswahl in der Detail-Ansicht (nicht gespeichert)
    @Published var appeared = false  // Pop-Animation beim Öffnen
    @Published var closing = false
    @Published private(set) var hovering = false  // Maus über Ablage oder Aktionsleiste
    @Published private(set) var dropping = false  // ein Drag schwebt über Ablage/Aktionsleiste (gilt bis `hovering` endet)
    /// Aktionsleiste sichtbar: beim Hovern mit Inhalt oder während ein Drag drüberschwebt (dann auch bei leerer Ablage).
    var showsActions: Bool { hovering && (!items.isEmpty || dropping) }
    private var hoverSources = Set<String>()
    private var hoverTask: Task<Void, Never>?
    private var idleTask: Task<Void, Never>?
    private var idleArmed = false  // leer geöffnet und noch nie befüllt
    var onChange: (() -> Void)?
    var onEmpty: (() -> Void)?
    private var scoped: [URL] = []
    private var orphans: [URL] = []  // entfernte Cache-Dateien, Empfänger liest evtl. noch – erst in discard() löschen

    nonisolated static let cacheDir: URL = FileManager.default
        .urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("DropShelf")

    init(id: UUID = UUID(), bookmarks: [Data] = []) {
        self.id = id
        for data in bookmarks {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope,
                                     relativeTo: nil, bookmarkDataIsStale: &stale) else { continue }
            let started = url.startAccessingSecurityScopedResource()
            guard FileManager.default.fileExists(atPath: url.path) else {
                if started { url.stopAccessingSecurityScopedResource() }
                continue
            }
            if started { scoped.append(url) }
            items.append(Item(url: url, bookmark: stale ? Self.bookmark(url) : data))
        }
    }

    /// Hover von mehreren Fenstern (Ablage + Aktionsleiste); Ausblenden leicht verzögert gegen Flackern.
    func setHover(_ key: String, _ on: Bool) {
        hoverTask?.cancel()
        if on {
            idleTask?.cancel()
            hoverSources.insert(key)
            if !hovering { hovering = true }
            if key.hasPrefix("drop") && !dropping { dropping = true }  // "drop", "dropbtn", "droprow"
            return
        }
        hoverSources.remove(key)
        guard hoverSources.isEmpty else { return }
        hoverTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            if !Task.isCancelled && self.hoverSources.isEmpty { self.hovering = false; self.dropping = false; self.restartIdleClose() }
        }
    }

    /// Leere Ablage schließt sich nach X s von selbst (nur wenn sie leer geöffnet und nie befüllt wurde).
    /// Pausiert unter Maus/Drag, startet danach mit voller Frist neu; Ablegen einer Datei beendet es.
    func armIdleClose() { idleArmed = items.isEmpty; restartIdleClose() }

    private func restartIdleClose() {
        idleTask?.cancel()
        let d = UserDefaults.standard
        guard idleArmed, items.isEmpty, !hovering, !expanded, d.object(forKey: "autoCloseEmptyEnabled") as? Bool ?? true else { return }
        let secs = min(max(d.object(forKey: "autoCloseEmptySeconds") as? Double ?? 5, 3), 30)
        idleTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(secs * 1_000_000_000))
            if !Task.isCancelled && self.idleArmed && self.items.isEmpty && !self.hovering && !self.closing { self.onEmpty?() }
        }
    }

    var bookmarkCount: Int { items.filter { $0.bookmark != nil }.count }

    /// Vergisst gespeicherte Zugriffe (Einträge bleiben für diese Sitzung).
    func forgetBookmarks() { for i in items.indices { items[i].bookmark = nil }; onChange?() }

    private static func bookmark(_ url: URL) -> Data? {
        try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    func add(_ url: URL) {
        guard !items.contains(where: { $0.url == url }) else { return }
        // Drag-Drop-URLs liefern evtl. false (Zugriff schon implizit erteilt) – trotzdem weitermachen.
        if url.startAccessingSecurityScopedResource() { scoped.append(url) }
        items.append(Item(url: url, bookmark: Self.bookmark(url)))  // nil = nur für diese Sitzung
        idleArmed = false; idleTask?.cancel()
        onChange?()
    }

    /// Nach Umbenennen (alt → neu): Eintrag bleibt an seiner Stelle mit gleicher ID, bekommt neue URL und neues Lesezeichen.
    /// Ein vergessenes Lesezeichen (nil, siehe `forgetBookmarks`) bleibt nil. Ein `onChange` für alle Änderungen.
    func replaceURLs(_ map: [URL: URL]) {
        let byPath = Dictionary(map.map { ($0.key.standardizedFileURL.path, $0.value) }, uniquingKeysWith: { a, _ in a })
        var changed = false
        for i in items.indices {
            guard let new = byPath[items[i].url.standardizedFileURL.path] else { continue }
            if new.startAccessingSecurityScopedResource() { scoped.append(new) }
            items[i] = Item(id: items[i].id, url: new, bookmark: items[i].bookmark == nil ? nil : Self.bookmark(new))
            changed = true
        }
        if changed { onChange?() }
    }

    func remove(_ urls: [URL]) {
        let gone = items.filter { urls.contains($0.url) }
        guard !gone.isEmpty else { return }
        // Wird die Ablage dadurch leer (Herausziehen, AirDrop, Leeren), den Stand vorher im Verlauf sichern.
        let archived = gone.count == items.count && HistoryStore.shared.add(items)
        items.removeAll { urls.contains($0.url) }
        if !archived { orphans += gone.map(\.url).filter(Self.isCacheFile) }
        // Scopes bleiben bis discard() offen, damit der Empfänger noch lesen kann.
        if items.isEmpty { expanded = false }
        onChange?()
        let auto = UserDefaults.standard.object(forKey: "autoCloseWhenEmpty") as? Bool ?? true
        if items.isEmpty && auto { Task { @MainActor in self.onEmpty?() } }
    }

    /// Gibt Zugriffe frei und löscht selbst erzeugte Cache-Dateien.
    /// `keepItems`: Dateien liegen jetzt im Verlauf – Cache-Dateien nicht löschen.
    func discard(keepItems: Bool = false) {
        scoped.forEach { $0.stopAccessingSecurityScopedResource() }
        scoped = []
        for url in (keepItems ? [] : items.map(\.url)) + orphans where Self.isCacheFile(url) {
            try? FileManager.default.removeItem(at: url)
        }
        items = []
        orphans = []
    }

    /// Löscht entfernte Cache-Dateien (beim Beenden; der Empfänger liest dann nicht mehr).
    func purgeOrphans() {
        orphans.forEach { try? FileManager.default.removeItem(at: $0) }
        orphans = []
    }

    nonisolated static func canonical(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }

    nonisolated static func isCacheFile(_ url: URL) -> Bool {
        canonical(url).hasPrefix(canonical(cacheDir) + "/")
    }

    /// Löscht alle Cache-Dateien, die in keiner Ablage mehr referenziert sind.
    nonisolated static func cleanCache(keeping urls: [URL]) {
        let keep = Set(urls.map(canonical))
        let files = (try? FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil)) ?? []
        for f in files where !keep.contains(canonical(f)) { try? FileManager.default.removeItem(at: f) }
    }

    // MARK: Drop

    func drop(_ providers: [NSItemProvider]) -> Bool {
        for p in providers {
            Self.resolve(p) { url in
                guard let url else { return }
                Task { @MainActor in self.add(url) }
            }
        }
        return !providers.isEmpty
    }

    /// Dateien direkt, sonst Bild/Link/Text als Cache-Datei; `done` kommt genau einmal (nil = nichts lesbar).
    nonisolated static func resolve(_ p: NSItemProvider, _ done: @escaping @Sendable (URL?) -> Void) {
        if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            _ = p.loadObject(ofClass: URL.self) { url, _ in done(url) }
        } else if p.canLoadObject(ofClass: NSImage.self) {
            _ = p.loadObject(ofClass: NSImage.self) { obj, _ in
                guard let tiff = (obj as? NSImage)?.tiffRepresentation,
                      let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return done(nil) }
                done(Self.cacheFile("Bild", "png", png))
            }
        } else if p.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return done(nil) }
                if url.isFileURL { return done(url) }
                let plist = try? PropertyListSerialization.data(
                    fromPropertyList: ["URL": url.absoluteString], format: .xml, options: 0)
                done(plist.flatMap { Self.cacheFile(url.host ?? "Link", "webloc", $0) })
            }
        } else if p.canLoadObject(ofClass: String.self) {
            _ = p.loadObject(ofClass: String.self) { text, _ in
                done(text.flatMap { Self.cacheFile("Text", "txt", Data($0.utf8)) })
            }
        } else {
            done(nil)
        }
    }

    @MainActor static func resolve(_ p: NSItemProvider) async -> URL? {
        await withCheckedContinuation { c in resolve(p) { c.resume(returning: $0) } }
    }

    nonisolated static func cacheFile(_ base: String, _ ext: String, _ data: Data) -> URL? {
        let safe = base.replacingOccurrences(of: "/", with: "-")
        let url = cacheDir.appendingPathComponent("\(safe) \(UUID().uuidString.prefix(6)).\(ext)")
        do {
            try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            try data.write(to: url)
            return url
        } catch { return nil }
    }
}

@MainActor
final class ShelfManager {
    static let shared = ShelfManager()
    private var panels: [UUID: ShelfPanel] = [:]
    var lastActive: UUID?  // zuletzt angeklickt/geändert/geöffnet
    private var canSave = false  // erst nach vollständigem restore(); bleibt false bei unlesbarer Datei
    private let file: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DropShelf")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("shelves.json")
    }()

    func restore() {
        let (records, writable): ([ShelfRecord], Bool) = PersistedList.load(file)
        for r in records {
            let onScreen = NSScreen.screens.contains { $0.frame.contains(r.origin) }
            open(Shelf(id: r.id, bookmarks: r.bookmarks), origin: onScreen ? r.origin : nil)
        }
        canSave = writable
        // ponytail: solange eine Sicherung existiert, bleibt der Cache ungeputzt (sie kann auf Cache-Dateien zeigen).
        if writable, !PersistedList.hasBackup(of: file), HistoryStore.shared.cacheIsSafeToClean {
            Shelf.cleanCache(keeping: panels.values.flatMap { $0.shelf.items.map(\.url) } + HistoryStore.shared.entries.flatMap(\.urls))
        }
        save()  // schreibt aufgeräumte Liste zurück (veraltete/fehlende Einträge)
    }

    var isEmpty: Bool { panels.isEmpty }

    /// Neue Ablage; mit `mouse` erscheint sie dort (Mauszeiger oben mittig), sonst oben rechts.
    func newShelf(at mouse: CGPoint? = nil) {
        open(Shelf(), origin: mouse.map(Self.origin))
    }

    /// Neue Ablage an der Maus, gefüllt aus der Zwischenablage (Dateien, sonst Bild, sonst URLs/Text); leer → Piepton.
    func newShelfFromClipboard() {
        let pb = NSPasteboard.general
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let files = pb.readObjects(forClasses: [NSURL.self], options: opts) as? [NSURL] ?? []
        let objects: [NSItemProviderWriting] = !files.isEmpty ? files
            : (pb.readObjects(forClasses: [NSImage.self]) as? [NSImage] ?? []).prefix(1).map { $0 as NSItemProviderWriting }
        let all = !objects.isEmpty ? objects : (pb.readObjects(forClasses: [NSURL.self, NSString.self]) as? [NSItemProviderWriting] ?? [])
        guard !all.isEmpty else { NSSound.beep(); return }
        let shelf = Shelf()
        open(shelf, origin: Self.origin(forMouse: NSEvent.mouseLocation))
        _ = shelf.drop(all.map { NSItemProvider(object: $0) })
    }

    private static func origin(forMouse m: CGPoint) -> CGPoint {
        CGPoint(x: m.x - ShelfPanel.width / 2, y: m.y - ShelfPanel.collapsedHeight + 40)
    }

    /// Ablage aus dem Verlauf als neue schwebende Ablage zurückholen.
    func restore(_ entry: HistoryStore.Entry, at mouse: CGPoint) {
        open(Shelf(bookmarks: entry.bookmarks), origin: Self.origin(forMouse: mouse))
        HistoryStore.shared.remove(entry.id, deleteFiles: false)
        save()
    }

    private func open(_ shelf: Shelf, origin: CGPoint?) {
        let spot = origin ?? defaultOrigin()
        lastActive = shelf.id
        shelf.onChange = { [weak self, id = shelf.id] in self?.lastActive = id; self?.save() }
        shelf.onEmpty = { [weak self, id = shelf.id] in self?.close(id) }
        let panel = ShelfPanel(shelf: shelf, origin: spot)
        panels[shelf.id] = panel
        panel.orderFrontRegardless()
        panel.popIn()
        shelf.armIdleClose()
        if origin == nil { save() }
    }

    private func defaultOrigin() -> CGPoint {
        let vf = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let n = CGFloat(panels.count % 8) * 24
        return CGPoint(x: vf.maxX - ShelfPanel.width - 20 - n, y: vf.maxY - ShelfPanel.collapsedHeight - 20 - n)
    }

    func close(_ id: UUID) {
        guard let panel = panels.removeValue(forKey: id) else { return }
        if lastActive == id { lastActive = panels.keys.first }
        let archived = HistoryStore.shared.add(panel.shelf.items)
        save()
        panel.animateOut { panel.shelf.discard(keepItems: archived); panel.close() }
    }

    var bookmarkCount: Int { panels.values.reduce(0) { $0 + $1.shelf.bookmarkCount } }

    func resetBookmarks() { panels.values.forEach { $0.shelf.forgetBookmarks() }; save() }

    /// Ziel für Ergebnisse aus eigenen Fenstern: `shelf`, solange sie offen ist, sonst die aktive, sonst eine neue.
    func target(for shelf: Shelf) -> Shelf {
        if panels[shelf.id] != nil { return shelf }
        if activeShelf == nil { newShelf() }
        return activeShelf ?? shelf
    }

    var activeShelf: Shelf? { lastActive.flatMap { panels[$0]?.shelf } ?? panels.values.first?.shelf }

    func purgeOrphans() { panels.values.forEach { $0.shelf.purgeOrphans() } }

    func save() {
        guard canSave else { return }
        let records = panels.values.map {
            ShelfRecord(id: $0.shelf.id, origin: $0.frame.origin, bookmarks: $0.shelf.items.compactMap(\.bookmark))
        }
        if let data = try? ShelfRecord.encode(records) { try? data.write(to: file, options: .atomic) }
    }
}
