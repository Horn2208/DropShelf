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
        case .images: return urls.filter { conforms($0, to: [.image]) }
        case .documents: return urls.filter { conforms($0, to: documentTypes) }
        case .media: return urls.filter { conforms($0, to: [.audiovisualContent]) }
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
