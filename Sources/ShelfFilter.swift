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

    /// Familie zusammengehöriger Endungen: eine Pille schaltet alle gemeinsam. `name` nil = Einzelendung.
    struct Family {
        let name: String?
        let exts: [String]
        let common: Bool   // direkt sichtbar; sonst unter „Weitere Formate“
    }

    private static func f(_ name: String?, _ exts: String, _ common: Bool = true) -> Family {
        Family(name: name, exts: exts.split(separator: " ").map(String.init), common: common)
    }

    /// Vorschläge: Endungen, die macOS (UTType) nicht von sich aus als Bild/Dokument/Medium erkennt.
    static let families: [Category: [Family]] = [
        .image: [f("Malprogramme", "xcf kra ora pdn"), f("Affinity", "afphoto afdesign"), f("Design", "sketch fig cdr"),
                 f("Kamera-RAW", "kdc x3f mef", false), f(nil, "dpx", false), f(nil, "pcx", false), f(nil, "jxr", false),
                 f(nil, "bpg", false), f(nil, "fits", false)],
        .document: [f("LibreOffice", "odt ods odp odf"), f("Word alt", "doc dot"), f("E-Books", "mobi azw3 fb2"),
                    f("Comics", "cbz cbr"), f(nil, "djvu"), f("LaTeX", "tex bib"),
                    f("Visio", "vsd vsdx", false), f("Markup", "adoc rst", false),
                    f("Sonstige Office", "wps wpd pub xps chm mht", false)],
        .media: [f("Matroska", "mkv mka"), f("Verlustfreies Audio", "ape wv tta mpc"), f("DVD/Video alt", "vob divx wtv"),
                 f("DSD-Audio", "dsf dff", false), f(nil, "dts", false)],
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
