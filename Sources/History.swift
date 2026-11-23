import AppKit

/// Verlauf geschlossener/geleerter Ablagen (neueste zuerst), als JSON mit Bookmarks in Application Support.
@MainActor
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()

    struct Record: Codable { var id: UUID; var date: Date; var bookmarks: [Data] }
    struct Entry: Identifiable {
        let id: UUID
        let date: Date
        var bookmarks: [Data]
        var urls: [URL]
        var title: String { urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) Dateien" }
    }

    @Published private(set) var entries: [Entry] = []
    private let file: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DropShelf")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }()

    static var enabled: Bool { UserDefaults.standard.object(forKey: "historyEnabled") as? Bool ?? true }
    static var limit: Int { UserDefaults.standard.object(forKey: "historyLimit") as? Int ?? 30 }

    private var canSave = true  // false: Datei war unlesbar, nicht überschreiben
    var cacheIsSafeToClean: Bool { canSave && !PersistedList.hasBackup(of: file) }

    private init() { load() }

    /// Lädt, löst Bookmarks auf und entfernt nicht mehr auflösbare Dateien bzw. leere Einträge.
    private func load() {
        let (records, writable): ([Record], Bool) = PersistedList.load(file)
        canSave = writable
        for r in records {
            var urls: [URL] = [], marks: [Data] = []
            for data in r.bookmarks {
                var stale = false
                guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale) else { continue }
                _ = url.startAccessingSecurityScopedResource()
                guard FileManager.default.fileExists(atPath: url.path) else { url.stopAccessingSecurityScopedResource(); continue }
                urls.append(url)
                marks.append(stale ? Self.bookmark(url) ?? data : data)
            }
            if !urls.isEmpty { entries.append(Entry(id: r.id, date: r.date, bookmarks: marks, urls: urls)) }
        }
        trim()
        save()
    }

    private static func bookmark(_ url: URL) -> Data? {
        try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// Legt den Stand einer Ablage vorn ab. Leere Ablagen und Dateien ohne Bookmark werden nicht gespeichert.
    @discardableResult
    func add(_ items: [Shelf.Item]) -> Bool {
        guard Self.enabled else { return false }
        let kept = items.filter { $0.bookmark != nil }
        guard !kept.isEmpty else { return false }
        kept.forEach { _ = $0.url.startAccessingSecurityScopedResource() }
        entries.insert(Entry(id: UUID(), date: Date(), bookmarks: kept.compactMap(\.bookmark), urls: kept.map(\.url)), at: 0)
        trim()
        save()
        return true
    }

    /// `deleteFiles`: selbst erzeugte Cache-Dateien löschen (nicht beim Wiederherstellen).
    func remove(_ id: UUID, deleteFiles: Bool = true) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        let e = entries.remove(at: i)
        for u in e.urls {
            u.stopAccessingSecurityScopedResource()
            if deleteFiles && Shelf.isCacheFile(u) { try? FileManager.default.removeItem(at: u) }
        }
        save()
    }

    func clear() { entries.map(\.id).forEach { remove($0) } }

    /// Auf die eingestellte Größe kürzen (auch nach Verkleinern der Einstellung).
    func trim() {
        while entries.count > Self.limit, let last = entries.last { remove(last.id) }
    }

    private func save() {
        guard canSave else { return }
        let records = entries.map { Record(id: $0.id, date: $0.date, bookmarks: $0.bookmarks) }
        if let data = try? JSONEncoder().encode(records) { try? data.write(to: file, options: .atomic) }
    }
}

extension HistoryStore.Record {
    /// Altes Schema: `id` und `date` haben Ersatzwerte, `bookmarks` sind der Inhalt und bleiben Pflicht.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        date = try c.decodeIfPresent(Date.self, forKey: .date) ?? PersistedList.unknownDate
        bookmarks = try c.decode([Data].self, forKey: .bookmarks)
    }
}
