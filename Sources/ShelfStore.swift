import AppKit
import UniformTypeIdentifiers

/// Speicherformat einer offenen Ablage.
struct ShelfRecord: Codable, Equatable {
    var id: UUID
    var origin: CGPoint
    var bookmarks: [Data]

    static func encode(_ records: [ShelfRecord]) throws -> Data { try JSONEncoder().encode(records) }
    static func decode(_ data: Data) -> [ShelfRecord] { (try? JSONDecoder().decode([ShelfRecord].self, from: data)) ?? [] }

    /// Einfacher Self-Check (nur Debug, beim Start).
    static func selfCheck() {
        let r = ShelfRecord(id: UUID(), origin: CGPoint(x: 10, y: 20), bookmarks: [Data([1, 2, 3])])
        assert((try? decode(encode([r]))) == [r], "ShelfRecord roundtrip")
        assert(decode(Data("kaputt".utf8)).isEmpty, "ShelfRecord decode garbage")
    }
}

@MainActor
final class Shelf: ObservableObject, Identifiable {
    struct Item: Identifiable {
        let id = UUID()
        let url: URL
        var bookmark: Data?
    }

    let id: UUID
    @Published private(set) var items: [Item] = []
    @Published var expanded = false
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

    private static func bookmark(_ url: URL) -> Data? {
        try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    func add(_ url: URL) {
        guard !items.contains(where: { $0.url == url }) else { return }
        // Drag-Drop-URLs liefern evtl. false (Zugriff schon implizit erteilt) – trotzdem weitermachen.
        if url.startAccessingSecurityScopedResource() { scoped.append(url) }
        items.append(Item(url: url, bookmark: Self.bookmark(url)))  // nil = nur für diese Sitzung
        onChange?()
    }

    func remove(_ urls: [URL]) {
        let gone = items.filter { urls.contains($0.url) }
        guard !gone.isEmpty else { return }
        items.removeAll { urls.contains($0.url) }
        orphans += gone.map(\.url).filter { $0.path.hasPrefix(Self.cacheDir.path) }
        // Scopes bleiben bis discard() offen, damit der Empfänger noch lesen kann.
        if items.isEmpty { expanded = false }
        onChange?()
        let auto = UserDefaults.standard.object(forKey: "autoCloseWhenEmpty") as? Bool ?? true
        if items.isEmpty && auto { Task { @MainActor in self.onEmpty?() } }
    }

    /// Gibt Zugriffe frei und löscht selbst erzeugte Cache-Dateien.
    func discard() {
        scoped.forEach { $0.stopAccessingSecurityScopedResource() }
        scoped = []
        for url in items.map(\.url) + orphans where url.path.hasPrefix(Self.cacheDir.path) {
            try? FileManager.default.removeItem(at: url)
        }
        items = []
        orphans = []
    }

    // MARK: Drop

    func drop(_ providers: [NSItemProvider]) -> Bool {
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in self.add(url) }
                }
            } else if p.canLoadObject(ofClass: NSImage.self) {
                _ = p.loadObject(ofClass: NSImage.self) { obj, _ in
                    guard let tiff = (obj as? NSImage)?.tiffRepresentation,
                          let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]),
                          let url = Self.cacheFile("Bild", "png", png) else { return }
                    Task { @MainActor in self.add(url) }
                }
            } else if p.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    let target: URL?
                    if url.isFileURL {
                        target = url
                    } else {
                        let plist = try? PropertyListSerialization.data(
                            fromPropertyList: ["URL": url.absoluteString], format: .xml, options: 0)
                        target = plist.flatMap { Self.cacheFile(url.host ?? "Link", "webloc", $0) }
                    }
                    guard let target else { return }
                    Task { @MainActor in self.add(target) }
                }
            } else if p.canLoadObject(ofClass: String.self) {
                _ = p.loadObject(ofClass: String.self) { text, _ in
                    guard let text, let url = Self.cacheFile("Text", "txt", Data(text.utf8)) else { return }
                    Task { @MainActor in self.add(url) }
                }
            }
        }
        return !providers.isEmpty
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
    private let file: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DropShelf")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("shelves.json")
    }()

    func restore() {
        let records = (try? Data(contentsOf: file)).map(ShelfRecord.decode) ?? []
        for r in records {
            let onScreen = NSScreen.screens.contains { $0.frame.contains(r.origin) }
            open(Shelf(id: r.id, bookmarks: r.bookmarks), origin: onScreen ? r.origin : nil)
        }
        save()  // schreibt aufgeräumte Liste zurück (veraltete/fehlende Einträge)
    }

    func newShelf() { open(Shelf(), origin: nil) }

    private func open(_ shelf: Shelf, origin: CGPoint?) {
        let spot = origin ?? defaultOrigin()
        shelf.onChange = { [weak self] in self?.save() }
        shelf.onEmpty = { [weak self, id = shelf.id] in self?.close(id) }
        let panel = ShelfPanel(shelf: shelf, origin: spot)
        panels[shelf.id] = panel
        panel.orderFrontRegardless()
        if origin == nil { save() }
    }

    private func defaultOrigin() -> CGPoint {
        let vf = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let n = CGFloat(panels.count % 8) * 24
        return CGPoint(x: vf.maxX - 220 - n, y: vf.maxY - 240 - n)
    }

    func close(_ id: UUID) {
        guard let panel = panels.removeValue(forKey: id) else { return }
        panel.shelf.discard()
        panel.close()
        save()
    }

    func save() {
        let records = panels.values.map {
            ShelfRecord(id: $0.shelf.id, origin: $0.frame.origin, bookmarks: $0.shelf.items.compactMap(\.bookmark))
        }
        if let data = try? ShelfRecord.encode(records) { try? data.write(to: file, options: .atomic) }
    }
}
