import Foundation

/// Finder-Tags (Funktionsschicht, keine UI). Eigene Datei statt Organize.swift (paralleles Paket 15.1).
enum FinderTags {
    static let standardNames = ["Rot", "Orange", "Gelb", "Grün", "Blau", "Lila", "Grau"]

    static func tags(of url: URL) -> [String] {
        (try? url.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []
    }

    static func setTags(_ tags: [String], on url: URL) throws {
        var seen = Set<String>()
        let unique = tags.filter { seen.insert($0).inserted }
        // URLResourceValues.tagNames hat den Setter erst ab macOS 26, Target ist macOS 14.
        try (url as NSURL).setResourceValue(unique, forKey: .tagNamesKey)
    }

    static func addTag(_ tag: String, to url: URL) throws {
        let current = tags(of: url)
        guard !current.contains(tag) else { return }
        try setTags(current + [tag], on: url)
    }

    static func removeTag(_ tag: String, from url: URL) throws {
        let current = tags(of: url)
        guard current.contains(tag) else { return }
        try setTags(current.filter { $0 != tag }, on: url)
    }
}
