import Foundation
import AppKit

/// Gespeicherter Eintrag für einen freigegebenen Ordner (E8).
struct FolderAccessEntry: Codable, Equatable, Sendable {
    let displayName: String
    let bookmark: Data
}

enum FolderAccessError: LocalizedError, Equatable {
    case notADirectory(String)
    case bookmarkFailed(String)

    var errorDescription: String? {
        switch self {
        case .notADirectory(let name):
            return "„\(name)“ ist kein Ordner und kann nicht freigegeben werden."
        case .bookmarkFailed(let reason):
            return "Die Ordnerfreigabe konnte nicht gespeichert werden: \(reason)"
        }
    }
}

/// Verwaltet vom Nutzer freigegebene Ordner als Security-Scoped Bookmarks (E8).
/// Speicherort (`UserDefaults`) und Start/Stop-Hooks sind injizierbar, damit hostlose Tests
/// nie echte Nutzerdaten berühren und die Scope-Logik deterministisch prüfen können.
final class FolderAccessStore: @unchecked Sendable {
    static let shared = FolderAccessStore()
    static let defaultKey = "com.horn2208.DropShelf.folderAccessBookmarks"

    private let defaults: UserDefaults
    private let key: String
    private let startAccess: @Sendable (URL) -> Bool
    private let stopAccess: @Sendable (URL) -> Void
    private let lock = NSLock()

    init(userDefaults: UserDefaults = .standard,
         key: String = FolderAccessStore.defaultKey,
         startAccess: @escaping @Sendable (URL) -> Bool = { $0.startAccessingSecurityScopedResource() },
         stopAccess: @escaping @Sendable (URL) -> Void = { $0.stopAccessingSecurityScopedResource() }) {
        self.defaults = userDefaults
        self.key = key
        self.startAccess = startAccess
        self.stopAccess = stopAccess
    }

    convenience init(suiteName: String,
                     key: String = FolderAccessStore.defaultKey,
                     startAccess: @escaping @Sendable (URL) -> Bool = { $0.startAccessingSecurityScopedResource() },
                     stopAccess: @escaping @Sendable (URL) -> Void = { $0.stopAccessingSecurityScopedResource() }) {
        self.init(userDefaults: UserDefaults(suiteName: suiteName) ?? .standard,
                  key: key,
                  startAccess: startAccess,
                  stopAccess: stopAccess)
    }

    /// Normalisiert Pfade inklusive Symlinks für exakte Eltern-/Vorfahrenvergleiche.
    static func normalize(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    /// Prüft, ob `folder` die Datei/den Ordner `target` direkt enthält, identisch ist oder ein Vorfahre ist.
    static func isCovering(folder: URL, target: URL) -> Bool {
        let f = normalize(folder).path
        let t = normalize(target).path
        if f == t { return true }
        let prefix = f.hasSuffix("/") ? f : f + "/"
        return t.hasPrefix(prefix)
    }

    /// Speichert einen Ordner als Security-Scoped Bookmark (ersetzt ggf. einen bestehenden Eintrag für denselben Pfad).
    func add(_ folder: URL) throws {
        let norm = Self.normalize(folder)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: norm.path, isDirectory: &isDir), isDir.boolValue else {
            throw FolderAccessError.notADirectory(folder.lastPathComponent)
        }
        let data: Data
        do {
            data = try norm.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        } catch {
            throw FolderAccessError.bookmarkFailed(error.localizedDescription)
        }
        let name = FileManager.default.displayName(atPath: norm.path)
        let entry = FolderAccessEntry(displayName: name, bookmark: data)

        lock.lock()
        defer { lock.unlock() }
        var list = loadEntriesLocked()
        list.removeAll { existing in
            var stale = false
            guard let resolved = try? URL(resolvingBookmarkData: existing.bookmark, options: .withSecurityScope,
                                          relativeTo: nil, bookmarkDataIsStale: &stale) else { return false }
            return Self.normalize(resolved).path == norm.path
        }
        list.append(entry)
        saveEntriesLocked(list)
    }

    /// Entfernt die Freigabe für einen Ordner (Vergleich über normalisierten Pfad).
    func remove(_ folder: URL) {
        let targetPath = Self.normalize(folder).path
        lock.lock()
        defer { lock.unlock() }
        var list = loadEntriesLocked()
        list.removeAll { entry in
            var stale = false
            guard let resolved = try? URL(resolvingBookmarkData: entry.bookmark, options: .withSecurityScope,
                                          relativeTo: nil, bookmarkDataIsStale: &stale) else { return false }
            return Self.normalize(resolved).path == targetPath
        }
        saveEntriesLocked(list)
    }

    /// Löst alle gespeicherten Bookmarks auf, erneuert veraltete (`isStale`) und überspringt unlösbare Einträge.
    func all() -> [URL] {
        lock.lock()
        defer { lock.unlock() }
        var list = loadEntriesLocked()
        var dirty = false
        var seen = Set<String>()
        var result: [URL] = []

        for i in list.indices {
            var stale = false
            guard let resolved = try? URL(resolvingBookmarkData: list[i].bookmark, options: .withSecurityScope,
                                          relativeTo: nil, bookmarkDataIsStale: &stale) else {
                continue
            }
            if stale,
               let refreshed = try? Self.normalize(resolved).bookmarkData(
                   options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil
               ) {
                let name = FileManager.default.displayName(atPath: resolved.path)
                list[i] = FolderAccessEntry(displayName: name, bookmark: refreshed)
                dirty = true
            }
            let path = Self.normalize(resolved).path
            if seen.insert(path).inserted {
                result.append(resolved)
            }
        }
        if dirty { saveEntriesLocked(list) }
        return result
    }

    /// Gespeicherte Roh-Einträge (z. B. für Anzeigenamen).
    func entries() -> [FolderAccessEntry] {
        lock.lock()
        defer { lock.unlock() }
        return loadEntriesLocked()
    }

    /// Liefert den spezifischsten freigegebenen Ordner, der `file` abdeckt (exakter Ordner, direkter Elternordner oder Vorfahre).
    func covering(_ file: URL) -> URL? {
        all()
            .filter { Self.isCovering(folder: $0, target: file) }
            .max { Self.normalize($0).path.count < Self.normalize($1).path.count }
    }

    /// Öffnet bei vorhandenem abdeckendem Ordner dessen Security-Scope, führt `body` aus und schließt den Scope garantiert.
    /// Ohne abdeckenden Ordner läuft `body` ohne Scope-Zugriff (kein Fehler).
    func withAccess<T>(to file: URL, _ body: (URL) throws -> T) rethrows -> T {
        if let folder = covering(file) {
            let started = startAccess(folder)
            defer { if started { stopAccess(folder) } }
            return try body(folder)
        }
        var isDir: ObjCBool = false
        let fallbackDir = (FileManager.default.fileExists(atPath: file.path, isDirectory: &isDir) && isDir.boolValue)
            ? file
            : file.deletingLastPathComponent()
        return try body(fallbackDir)
    }

    /// Öffnet ein NSOpenPanel zur Ordnerfreigabe (nur Ordner, Start im Elternordner der Datei) und speichert die Wahl.
    /// Wird nie in Tests aufgerufen.
    @MainActor
    func requestAccess(for file: URL) async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Ordner freigeben"
        panel.message = "Ordner freigeben, um Dateien neben dem Original zu speichern oder dort umzubenennen."
        var isDir: ObjCBool = false
        let dir = (FileManager.default.fileExists(atPath: file.path, isDirectory: &isDir) && isDir.boolValue)
            ? file
            : file.deletingLastPathComponent()
        panel.directoryURL = dir

        let response = await panel.begin()
        guard response == .OK, let chosen = panel.url else { return nil }
        try? add(chosen)
        return chosen
    }

    // MARK: Intern (inkl. Test-Helfer)

    func appendRawEntry(_ entry: FolderAccessEntry) {
        lock.lock()
        defer { lock.unlock() }
        var list = loadEntriesLocked()
        list.append(entry)
        saveEntriesLocked(list)
    }

    private func loadEntriesLocked() -> [FolderAccessEntry] {
        guard let data = defaults.data(forKey: key),
              let entries = try? JSONDecoder().decode([FolderAccessEntry].self, from: data)
        else { return [] }
        return entries
    }

    private func saveEntriesLocked(_ entries: [FolderAccessEntry]) {
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: key)
        }
    }
}
