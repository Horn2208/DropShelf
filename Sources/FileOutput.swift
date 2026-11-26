import Foundation

/// Wohin ein Werkzeug-Ergebnis kommt. Überschrieben wird nur bei `.replaceOriginal`.
enum OutputMode: Sendable { case besideOriginal, cache, replaceOriginal }

enum FileOutputError: LocalizedError {
    /// Kein Fehler im engeren Sinn: das Ergebnis liegt trotzdem im Cache (siehe `FileOutput.Placement.notice`).
    case noWriteAccess(folder: String)
    case cacheFailed(String)

    var errorDescription: String? {
        switch self {
        case .noWriteAccess(let folder):
            return "Kein Schreibzugriff auf „\(folder)“ – das Ergebnis liegt in der Ablage. Ordner freigeben, um neben das Original zu speichern."
        case .cacheFailed(let reason):
            return "Das Ergebnis konnte nicht gespeichert werden: \(reason)"
        }
    }
}

/// Legt eine fertige Temp-Datei sicher ab (PLAN.md „Ausgabe- und Sandbox-Regel“):
/// neben das Original, sonst in `cacheDir`; das Original wird nur bei `.replaceOriginal` ersetzt.
enum FileOutput {
    struct Placement: Sendable {
        let url: URL
        /// Gesetzt, wenn statt neben/über das Original in den Cache ausgewichen wurde.
        let fallback: FileOutputError?
        var inCache: Bool { fallback != nil }
        var notice: String? { fallback?.errorDescription }
    }

    static func place(_ tmp: URL, for source: URL, suffix: String, ext: String,
                      mode: OutputMode, cacheDir: URL,
                      folderAccess: FolderAccessStore = .shared) throws -> URL {
        try placeReporting(tmp, for: source, suffix: suffix, ext: ext, mode: mode,
                           cacheDir: cacheDir, folderAccess: folderAccess).url
    }

    /// Wie `place`, meldet aber, ob auf den Cache zurückgefallen wurde (für die Meldung an den Nutzer).
    static func placeReporting(_ tmp: URL, for source: URL, suffix: String, ext: String,
                               mode: OutputMode, cacheDir: URL,
                               folderAccess: FolderAccessStore = .shared) throws -> Placement {
        let base = source.deletingPathExtension().lastPathComponent
        let dir = source.deletingLastPathComponent()

        if mode != .cache {
            func writeToOriginalFolder() throws -> URL {
                mode == .replaceOriginal
                    ? try replace(source, with: tmp, base: base, ext: ext)
                    : try moveFree(tmp, into: dir, base: base, suffix: suffix, ext: ext)
            }

            // Bookmark-Zugriff hängt an der Original-URL; ein freigegebener Ordner trägt seinen eigenen Scope.
            let started = source.startAccessingSecurityScopedResource()
            defer { if started { source.stopAccessingSecurityScopedResource() } }
            if let url = try? writeToOriginalFolder() {
                return Placement(url: url, fallback: nil)
            }
            if folderAccess.covering(source) != nil,
               let url = try? folderAccess.withAccess(to: source, { _ in try writeToOriginalFolder() }) {
                return Placement(url: url, fallback: nil)
            }
        }

        do {
            try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            let url = try moveFree(tmp, into: cacheDir, base: base, suffix: suffix, ext: ext)
            let folder = FileManager.default.displayName(atPath: dir.path)
            return Placement(url: url, fallback: mode == .cache ? nil : .noWriteAccess(folder: folder))
        } catch {
            throw FileOutputError.cacheFailed(error.localizedDescription)
        }
    }

    /// „Foto (bearbeitet).png“, „Foto (bearbeitet 2).png“ … (ohne Suffix: „Foto.png“, „Foto 2.png“).
    static func candidateName(base: String, suffix: String, ext: String, n: Int) -> String {
        let tag = suffix.isEmpty ? (n == 1 ? "" : " \(n)") : " (\(suffix)\(n == 1 ? "" : " \(n)"))"
        let name = (base + tag).replacingOccurrences(of: "/", with: "-")
        return ext.isEmpty ? name : "\(name).\(ext)"
    }

    /// `moveItem` schlägt fehl, wenn das Ziel existiert – so wird nie überschrieben, auch nicht bei Wettläufen.
    private static func moveFree(_ tmp: URL, into dir: URL, base: String, suffix: String, ext: String) throws -> URL {
        for n in 1...999 {
            let dest = dir.appendingPathComponent(candidateName(base: base, suffix: suffix, ext: ext, n: n))
            do {
                try FileManager.default.moveItem(at: tmp, to: dest)
                return dest
            } catch CocoaError.fileWriteFileExists {
                continue
            }
        }
        throw CocoaError(.fileWriteFileExists)
    }

    /// Ersetzt das Original atomar. Ändert sich die Endung (z. B. PNG → JPG), bekommt die Datei danach
    /// einen freien Namen mit der neuen Endung.
    private static func replace(_ source: URL, with tmp: URL, base: String, ext: String) throws -> URL {
        guard let result = try FileManager.default.replaceItemAt(source, withItemAt: tmp) else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard !ext.isEmpty, ext.lowercased() != source.pathExtension.lowercased() else { return result }
        // Umbenennen scheitert? Dann bleibt das ersetzte Original unter altem Namen – Inhalt ist sicher.
        return (try? moveFree(result, into: result.deletingLastPathComponent(), base: base, suffix: "", ext: ext)) ?? result
    }
}
