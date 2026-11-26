import AppKit
import AVFoundation
import UniformTypeIdentifiers

/// Rechtsklick-Untermenü „Bearbeiten“: reine Logik (testbar), Menü-Aufbau und Hintergrund-Aufträge.
enum EditMenu {
    /// Welche Dateien jeder Menüpunkt bearbeitet; leer = Punkt erscheint nicht.
    struct Plan: Equatable {
        var merge: [URL]
        var compress: [URL]
        /// Fenster-Werkzeuge: nur bei genau einer passenden Datei.
        var pages: URL? = nil
        var trim: URL? = nil
        var image: URL? = nil
        var isEmpty: Bool { merge.isEmpty && compress.isEmpty && pages == nil && trim == nil && image == nil }
    }

    /// Ergebnis eines Auftrags (`ConvertJobs.run`): neue Dateien für die Ablage und höchstens eine Meldung.
    struct Outcome: Sendable {
        var add: [URL] = []
        var notice: String? = nil
        /// Für „Ordner freigeben…“ im Banner (nur bei Cache-Rückfall).
        var folderFor: URL? = nil
    }

    /// Endungen, bei denen „Kürzen …“ erscheint (jede per Test belegt).
    static let trimExtensions: Set<String> = ["mov", "mp4", "m4v", "mp3", "m4a", "wav", "aif", "aiff", "caf"]

    /// Große Ansicht: Ist die angeklickte Datei markiert, alle markierten in Anzeigereihenfolge, sonst nur sie.
    static func targetURLs(clicked: UUID, selection: Selection, items: [Shelf.Item]) -> [URL] {
        let ids = selection.ids.contains(clicked) ? selection.order.filter(selection.ids.contains) : [clicked]
        return ids.compactMap { id in items.first { $0.id == id }?.url }
    }

    static func plan(_ urls: [URL]) -> Plan {
        // Typ wie in `PDFTools.merge`: nach Endung.
        func isType(_ url: URL, _ t: UTType) -> Bool { UTType(filenameExtension: url.pathExtension)?.conforms(to: t) == true }
        let mergeable = urls.filter { isType($0, .pdf) || isType($0, .image) }
        let pdfs = urls.filter { isType($0, .pdf) }
        let media = urls.filter { trimExtensions.contains($0.pathExtension.lowercased()) }
        let images = urls.filter { isType($0, .image) || FileFormats.has($0, .image) }
        return Plan(merge: mergeable.count >= 2 ? mergeable : [], compress: pdfs,
                    pages: pdfs.count == 1 ? pdfs[0] : nil, trim: media.count == 1 ? media[0] : nil,
                    image: urls.count == 1 && images.count == 1 ? images[0] : nil)
    }

    // MARK: Menü

    /// „Bearbeiten ▸“ für die Zielmenge (in Anzeigereihenfolge); passt nichts: nil.
    @MainActor static func menuItem(for urls: [URL], shelf: Shelf) -> NSMenuItem? {
        let p = plan(urls)
        guard !p.isEmpty else { return nil }
        let sub = NSMenu()
        if !p.merge.isEmpty {
            sub.addItem(ActionMenuItem("Zu PDF zusammenfügen") {
                ConvertJobs.shared.run(p.merge, shelf: shelf, failure: "Zusammenfügen fehlgeschlagen") { try mergeJob(urls) }
            })
        }
        if !p.compress.isEmpty {
            let levels = NSMenu()
            for (title, level) in [("Gering", CompressionLevel.low), ("Mittel", .medium), ("Stark", .high)] {
                levels.addItem(ActionMenuItem(title) { compress(p.compress, level: level, shelf: shelf) })
            }
            let i = NSMenuItem(title: "Komprimieren", action: nil, keyEquivalent: "")
            i.submenu = levels
            sub.addItem(i)
        }
        if let url = p.pages { sub.addItem(ActionMenuItem("Seiten verwalten …") { EditWindow.openPages(url, shelf: shelf) }) }
        if let url = p.trim { sub.addItem(ActionMenuItem("Kürzen …") { EditWindow.openTrim(url, shelf: shelf) }) }
        if let url = p.image { sub.addItem(ActionMenuItem("Bild bearbeiten …") { EditWindow.openImage(url, shelf: shelf) }) }
        let item = NSMenuItem(title: "Bearbeiten", action: nil, keyEquivalent: "")
        item.submenu = sub
        return item
    }

    /// Bei „Stark“ fragt `confirm` vorher nach; sind Dateien schon beschäftigt, passiert nichts (auch keine Frage).
    @MainActor static func compress(_ urls: [URL], level: CompressionLevel, shelf: Shelf, jobs: ConvertJobs = .shared,
                                    confirm: @MainActor (String) -> Bool = confirmStrong) {
        guard jobs.busy.isDisjoint(with: urls) else { return }
        if let warning = level.warning, !confirm(warning) { return }
        jobs.run(urls, shelf: shelf, failure: "Komprimieren fehlgeschlagen") { compressJob(urls, level: level) }
    }

    @MainActor static func confirmStrong(_ warning: String) -> Bool {
        NSApp.activate()
        let a = NSAlert()
        a.messageText = "Stark komprimieren?"
        a.informativeText = warning
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "Abbrechen")
        return a.runModal() == .alertFirstButtonReturn
    }

    // MARK: Aufträge (laufen im Hintergrund)

    static func trimJob(_ url: URL, range: CMTimeRange, cacheDir: URL = Shelf.cacheDir) async throws -> Outcome {
        Outcome(try await MediaTrim.trim(url, range: range, mode: .besideOriginal, cacheDir: cacheDir), for: url)
    }

    /// `urls` = ganze Zielmenge, damit auch nicht passende Dateien in der Meldung stehen.
    /// Name und Ort bestimmt die erste PDF-/Bild-Datei.
    static func mergeJob(_ urls: [URL], cacheDir: URL = Shelf.cacheDir) throws -> Outcome {
        let inputs = plan(urls).merge
        let r = try PDFTools.merge(inputs, mode: .besideOriginal, cacheDir: cacheDir)
        let skipped = urls.filter { !inputs.contains($0) || r.skipped.contains($0) }
        return Outcome(add: [r.url], notice: mergeNotice(skipped: skipped, notice: r.placement.notice),
                       folderFor: r.placement.inCache ? inputs.first { !r.skipped.contains($0) } : nil)
    }

    /// Nacheinander; eine kaputte oder gesperrte PDF bricht die übrigen nicht ab.
    static func compressJob(_ urls: [URL], level: CompressionLevel, cacheDir: URL = Shelf.cacheDir) -> Outcome {
        var out = Outcome()
        var notSmaller: [URL] = [], failures: [String] = [], notices: [String] = []
        for url in urls {
            do {
                let r = try PDFTools.compress(url, level: level, mode: .besideOriginal, cacheDir: cacheDir)
                guard let p = r.placement else { notSmaller.append(url); continue }
                out.add.append(p.url)
                if let n = p.notice {
                    notices.append(n)
                    out.folderFor = out.folderFor ?? url  // ponytail: ein Knopf; weitere Ordner beim nächsten Mal
                }
            } catch {
                failures.append("Komprimieren von „\(url.lastPathComponent)“ fehlgeschlagen: \(error.localizedDescription)")
            }
        }
        out.notice = compressNotice(notSmaller: notSmaller, failures: failures, notices: notices)
        return out
    }

    // MARK: Meldungen

    private static func names(_ urls: [URL]) -> String { urls.map { "„\($0.lastPathComponent)“" }.joined(separator: ", ") }

    static func mergeNotice(skipped: [URL], notice: String?) -> String? {
        let lines = [skipped.isEmpty ? nil : "Nicht ins PDF übernommen: \(names(skipped)).", notice].compactMap { $0 }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    static func compressNotice(notSmaller: [URL], failures: [String], notices: [String]) -> String? {
        var lines = failures
        if !notSmaller.isEmpty { lines.append("Nicht kleiner geworden, daher nichts hinzugefügt: \(names(notSmaller)).") }
        for n in notices where !lines.contains(n) { lines.append(n) }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}

extension EditMenu.Outcome {
    /// Eine abgelegte Datei; bei Cache-Rückfall mit Hinweis und Ordnerknopf für `source`.
    init(_ p: FileOutput.Placement, for source: URL) {
        self.init(add: [p.url], notice: p.notice, folderFor: p.inCache ? source : nil)
    }
}
