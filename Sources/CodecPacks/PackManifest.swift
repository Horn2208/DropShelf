import Foundation

struct Pack: Codable, Sendable, Identifiable {
    let id: String
    let version: String
    let url: URL
    let sha256: String
    /// Dateiendungen, die das Paket liest oder schreibt.
    let formats: [String]
    let apiVersion: Int
}

struct PackManifest: Codable, Sendable {
    let packs: [Pack]

    static func decode(_ data: Data) throws -> PackManifest { try JSONDecoder().decode(PackManifest.self, from: data) }

    /// Manifest aus dem Bundle; ohne Datei (z. B. in Tests) leer.
    static let bundled: PackManifest = {
        Bundle.main.url(forResource: "codec-packs", withExtension: "json")
            .flatMap { try? Data(contentsOf: $0) }.flatMap { try? decode($0) } ?? PackManifest(packs: [])
    }()

    func pack(for ext: String) -> Pack? {
        packs.first { $0.formats.contains { $0.caseInsensitiveCompare(ext) == .orderedSame } }
    }
}
