import Foundation

/// Installierte Pakete (UserDefaults `installedCodecs`: id → ["path", "version"]).
enum PackRegistry {
    static let key = "installedCodecs"

    private static func entries(_ d: UserDefaults) -> [String: [String: String]] {
        d.dictionary(forKey: key) as? [String: [String: String]] ?? [:]
    }

    /// Nur installiert, wenn die Datei noch da ist.
    static func installedURL(_ id: String, _ d: UserDefaults = .standard) -> URL? {
        guard let p = entries(d)[id]?["path"], FileManager.default.fileExists(atPath: p) else { return nil }
        return URL(fileURLWithPath: p)
    }
    static func isInstalled(_ id: String, _ d: UserDefaults = .standard) -> Bool { installedURL(id, d) != nil }
    static func installedVersion(_ id: String, _ d: UserDefaults = .standard) -> String? {
        isInstalled(id, d) ? entries(d)[id]?["version"] : nil
    }

    static func markInstalled(_ pack: Pack, at url: URL, _ d: UserDefaults = .standard) {
        var e = entries(d)
        e[pack.id] = ["path": url.path, "version": pack.version]
        d.set(e, forKey: key)
    }

    /// Entfernt den Eintrag und die Dateien des Pakets.
    static func remove(_ id: String, _ d: UserDefaults = .standard) {
        var e = entries(d)
        if let p = e[id]?["path"] { try? FileManager.default.removeItem(at: URL(fileURLWithPath: p).deletingLastPathComponent()) }
        e[id] = nil
        d.set(e, forKey: key)
    }
}

enum PackInstall {
    /// Herunterladen, prüfen, eintragen und Menü-Cache leeren.
    @MainActor static func run(_ pack: Pack, progress: @escaping @Sendable (Double) -> Void) async throws {
        let url = try await PackDownloader.shared.install(pack, progress: progress)
        PackRegistry.markInstalled(pack, at: url)
        ConvertMenu.resetCache()
    }
}
