import Foundation
import UniformTypeIdentifiers

/// Smarte Filter für Shelf-Einträge (Funktionsschicht, keine UI).
enum ShelfFilter: Equatable {
    case all, images, documents, media
    /// Die letzten N Einträge der Eingabereihenfolge (Einfügereihenfolge).
    case recent(Int)
    case tag(String)

    private static let documentTypes: [UTType] = [.pdf, .text, .presentation, .spreadsheet, .compositeContent]

    /// Filtert unter Beibehaltung der Eingabereihenfolge.
    static func apply(_ urls: [URL], _ f: ShelfFilter) -> [URL] {
        switch f {
        case .all: return urls
        case .images: return urls.filter { conforms($0, to: [.image]) || FileFormats.has($0, .image) }
        case .documents: return urls.filter { conforms($0, to: documentTypes) || FileFormats.has($0, .document) }
        case .media: return urls.filter { conforms($0, to: [.audiovisualContent]) || FileFormats.has($0, .media) }
        case .recent(let n): return Array(urls.suffix(max(0, n)))
        case .tag(let name): return urls.filter { FinderTags.tags(of: $0).contains(name) }
        }
    }

    private static func conforms(_ url: URL, to types: [UTType]) -> Bool {
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
            ?? UTType(filenameExtension: url.pathExtension)
        guard let type else { return false }
        return types.contains { type.conforms(to: $0) }
    }
}

/// Vom Nutzer ergänzte Dateiendungen samt Kategorie (Einstellungen ▸ Dateiformate).
enum FileFormats {
    enum Category: String, Codable, CaseIterable {
        case image, document, media
        var title: String { self == .image ? "Bild" : self == .document ? "Dokument" : "Medien" }
    }
    struct Entry: Codable, Hashable {
        var ext: String
        var category: Category
        var enabled = true

        init(ext: String, category: Category, enabled: Bool = true) {
            self.ext = ext; self.category = category; self.enabled = enabled
        }

        // Ältere gespeicherte Einträge haben kein „enabled“: gelten als aktiv.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            ext = try c.decode(String.self, forKey: .ext)
            category = try c.decode(Category.self, forKey: .category)
            enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        }
    }

    /// Vorschläge: Endungen, die macOS (UTType) nicht von sich aus als Bild/Dokument/Medium erkennt.
    static let suggestions: [Category: [String]] = [
        .image: ["xcf", "kra", "ora", "pdn", "afphoto", "afdesign", "sketch", "fig", "cdr", "pcx", "jxr", "bpg", "fits", "dpx", "kdc", "x3f", "mef"],
        .document: ["odt", "ods", "odp", "odf", "doc", "dot", "tex", "bib", "mobi", "azw3", "djvu", "cbz", "cbr", "fb2", "chm", "xps",
                    "wps", "wpd", "pub", "vsd", "vsdx", "mht", "adoc", "rst"],
        .media: ["mkv", "mka", "ape", "wv", "tta", "dsf", "dff", "dts", "vob", "divx", "wtv", "mpc"],
    ]

    static let key = "extraFileFormats"

    static func load() -> [Entry] {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
    }

    static func save(_ entries: [Entry]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(entries), forKey: key)
    }

    /// Klein, ohne Punkt und Leerraum; nur Buchstaben/Ziffern; sonst nil.
    static func normalize(_ raw: String) -> String? {
        var e = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if e.hasPrefix(".") { e.removeFirst() }
        return !e.isEmpty && e.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) ? e : nil
    }

    static func has(_ url: URL, _ c: Category) -> Bool {
        let e = url.pathExtension.lowercased()
        return load().contains { $0.enabled && $0.ext == e && $0.category == c }
    }
}
