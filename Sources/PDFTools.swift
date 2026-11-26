import Foundation
import AppKit
import PDFKit
import Quartz
import UniformTypeIdentifiers

enum PDFToolsError: LocalizedError {
    case nothingToMerge, writeFailed, nothingToSave, unreadable

    var errorDescription: String? {
        switch self {
        case .nothingToSave: return "Das Dokument hat keine Seiten und wird nicht gespeichert."
        case .nothingToMerge: return "Es gibt nichts zum Zusammenfügen: Nur PDFs und Bilder werden unterstützt."
        case .writeFailed: return "Die PDF-Datei konnte nicht geschrieben werden."
        case .unreadable: return "Die PDF-Datei kann nicht gelesen werden (beschädigt oder mit Passwort geschützt)."
        }
    }
}

/// Ergebnis von `PDFTools.merge`: Ablage (inkl. Cache-Hinweis) und die übersprungenen Eingaben (in Eingabereihenfolge).
struct PDFMergeResult {
    let placement: FileOutput.Placement
    let skipped: [URL]
    var url: URL { placement.url }
}

/// Stufe für `PDFTools.compress`.
enum CompressionLevel: Sendable, CaseIterable {
    /// Bilder als JPEG speichern.
    case low
    /// Zusätzlich Bilder auf Bildschirmauflösung verkleinern.
    case medium
    /// Bilder auf ca. 100 dpi / JPEG-Qualität 0,5 herunterrechnen (Quartz-Filter); Text bleibt Vektor.
    case high

    /// Hinweis für den Nutzer vor dem Komprimieren, nil wenn nichts verloren geht außer Bildqualität.
    var warning: String? {
        self == .high
            ? "Starke Komprimierung: Bilder verlieren deutlich an Schärfe. Links, Formularfelder und Lesezeichen gehen verloren, Anmerkungen werden fest eingezeichnet."
            : nil
    }
}

/// Ergebnis von `PDFTools.compress`. Wird die Datei nicht kleiner, wird nichts abgelegt und nichts ersetzt:
/// dann `isSmaller == false`, `placement == nil` und `url` ist die Quelle; die UI meldet das statt „komprimiert“.
struct PDFCompressionResult {
    let url: URL
    let originalSize: Int64
    /// Größe des Versuchs (auch wenn er verworfen wurde).
    let newSize: Int64
    /// Ablage mit Cache-Hinweis (`notice`/`inCache`); nil, wenn nichts abgelegt wurde.
    let placement: FileOutput.Placement?
    var isSmaller: Bool { newSize < originalSize }
}

/// Reine PDF-Funktionen auf URLs (kein UI). Ergebnisse gehen über `FileOutput`.
enum PDFTools {
    // MARK: 14.1 Zusammenfügen

    /// Fügt PDFs (alle Seiten) und Bilder (je eine Seite) in Listenreihenfolge zu einer PDF zusammen.
    /// Basis für Name/Ort ist die erste übernommene Datei. Andere Typen und unlesbare Dateien landen in `skipped`;
    /// bleibt nichts übrig: `.nothingToMerge`. `.replaceOriginal` ersetzt nie eine Eingabe (wie `.besideOriginal`).
    static func merge(_ urls: [URL], mode: OutputMode = .besideOriginal,
                      cacheDir: URL = Shelf.cacheDir) throws -> PDFMergeResult {
        let doc = PDFDocument()
        var skipped: [URL] = []
        // Zugriff bis nach dem Schreiben halten: PDFKit liest Seiten der Quellen erst beim Schreiben.
        var scoped: [URL] = []
        defer { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }
        // Quelldokumente ebenso: ohne sie lösen sich Link-Ziele beim Schreiben nicht mehr auf.
        var sources: [PDFDocument] = []
        for url in urls {
            if url.startAccessingSecurityScopedResource() { scoped.append(url) }

            let type = UTType(filenameExtension: url.pathExtension)
            if type?.conforms(to: .pdf) == true, let src = PDFDocument(url: url), src.pageCount > 0 {
                sources.append(src)
                for i in 0..<src.pageCount {
                    // Anmerkungen noch im Quelldokument laden (siehe `compress`), sonst brechen interne Links.
                    if let p = src.page(at: i) { _ = p.annotations; doc.insert(p, at: doc.pageCount) }
                }
            } else if type?.conforms(to: .image) == true, let img = NSImage(contentsOf: url),
                      let page = PDFPage(image: img) {
                doc.insert(page, at: doc.pageCount)
            } else {
                skipped.append(url)
            }
        }
        guard doc.pageCount > 0, let first = urls.first(where: { !skipped.contains($0) }) else { throw PDFToolsError.nothingToMerge }

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        do {
            guard withExtendedLifetime(sources, { doc.write(to: tmp) }) else { throw PDFToolsError.writeFailed }
            let placed = try FileOutput.placeReporting(tmp, for: first, suffix: "zusammengefügt", ext: "pdf",
                                                       mode: mode == .replaceOriginal ? .besideOriginal : mode,
                                                       cacheDir: cacheDir)
            return PDFMergeResult(placement: placed, skipped: skipped)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
    }

    // MARK: 14.2 Seitenoperationen
    // Indizes sind 0-basiert. Ungültige Indizes werden still ignoriert (kein Absturz, kein Fehler);
    // Funktionen mit Rückgabe melden, ob etwas geändert wurde.

    /// Dreht eine Seite um `degrees` (±90 …), Ergebnis auf 0..<360 normalisiert.
    @discardableResult
    static func rotate(page index: Int, by degrees: Int, in doc: PDFDocument) -> Bool {
        guard let p = doc.page(at: index) else { return false }
        p.rotation = (((p.rotation + degrees) % 360) + 360) % 360
        return true
    }

    /// PDFKit lädt Anmerkungen erst bei Bedarf und löst Link-Ziele dann über die Seitennummer auf:
    /// vor jedem Umbau alle Link-Ziele auflösen, sonst zeigen interne Links danach auf falsche Seiten.
    private static func resolveLinks(_ doc: PDFDocument) {
        for i in 0..<doc.pageCount { for a in doc.page(at: i)?.annotations ?? [] { _ = linkTarget(a)?.page } }
    }

    /// Zielseite eines internen Links; nil bei Web-Links und anderen Anmerkungen.
    private static func linkTarget(_ a: PDFAnnotation) -> PDFDestination? {
        a.type == "Link" ? (a.action as? PDFActionGoTo)?.destination ?? a.destination : nil
    }

    /// Entfernt die Seiten (von hinten, damit Indizes stabil bleiben), samt Links, die auf sie zeigen.
    /// Gibt die Zahl entfernter Seiten zurück.
    @discardableResult
    static func delete(pages: IndexSet, in doc: PDFDocument) -> Int {
        let valid = pages.filter { $0 >= 0 && $0 < doc.pageCount }
        resolveLinks(doc)
        let gone = Set(valid.compactMap { doc.page(at: $0) })
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            for a in page.annotations where linkTarget(a)?.page.map(gone.contains) == true { page.removeAnnotation(a) }
        }
        for i in valid.sorted(by: >) { doc.removePage(at: i) }
        return valid.count
    }

    /// Verschiebt Seite `from` so, dass sie danach an Index `to` steht (`to` wird auf das Ende begrenzt).
    @discardableResult
    static func move(from: Int, to: Int, in doc: PDFDocument) -> Bool {
        guard let p = doc.page(at: from), to >= 0 else { return false }
        resolveLinks(doc)
        doc.removePage(at: from)
        doc.insert(p, at: min(to, doc.pageCount))
        return true
    }

    /// Neues Dokument mit Kopien der Seiten in der angegebenen Reihenfolge; das Original bleibt unverändert.
    /// Interne Links zeigen auf die Kopie ihrer Zielseite; fehlt die im Auszug, entfällt der Link.
    static func extract(pages: [Int], from doc: PDFDocument) -> PDFDocument {
        resolveLinks(doc)
        let out = PDFDocument()
        var copies: [(original: PDFPage, copy: PDFPage)] = []
        for i in pages {
            guard let p = doc.page(at: i), let c = p.copy() as? PDFPage else { continue }
            out.insert(c, at: out.pageCount)
            copies.append((p, c))
        }
        for (original, copy) in copies {
            for (a, c) in zip(original.annotations, copy.annotations) {
                guard let dest = linkTarget(a), let target = dest.page else { continue }
                if let new = copies.first(where: { $0.original === target })?.copy {
                    c.action = PDFActionGoTo(destination: PDFDestination(page: new, at: dest.point))
                } else {
                    copy.removeAnnotation(c)
                }
            }
        }
        return out
    }

    /// Vorschaubild einer Seite; nil bei ungültigem Index.
    static func thumbnail(of index: Int, in doc: PDFDocument, size: CGSize) -> NSImage? {
        doc.page(at: index)?.thumbnail(of: size, for: .mediaBox)
    }

    /// Legt ein bearbeitetes Dokument über `FileOutput` ab (Temp → place), Suffix z. B. „bearbeitet“.
    /// Die `Placement` meldet einen Rückfall in den Cache (`notice`).
    static func save(_ doc: PDFDocument, for source: URL, suffix: String = "bearbeitet",
                     mode: OutputMode = .besideOriginal, cacheDir: URL = Shelf.cacheDir) throws -> FileOutput.Placement {
        guard doc.pageCount > 0 else { throw PDFToolsError.nothingToSave }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        do {
            guard doc.write(to: tmp) else { throw PDFToolsError.writeFailed }
            return try FileOutput.placeReporting(tmp, for: source, suffix: suffix, ext: "pdf", mode: mode, cacheDir: cacheDir)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
    }

    // MARK: 14.3 Komprimieren

    /// Komprimiert eine PDF (Suffix „komprimiert“). Seitenzahl bleibt gleich, Text bleibt auswählbar.
    /// Gering/Mittel: PDFKit-Schreiboptionen. Die greifen nur, wenn PDFKit das Dokument neu erzeugt –
    /// deshalb werden die Seiten erst in ein neues `PDFDocument` übernommen (ein unverändert
    /// geladenes Dokument schreibt PDFKit 1:1 zurück).
    /// Stark: Seiten werden über einen Quartz-Filter in einen neuen PDF-Kontext gezeichnet, der
    /// eingebettete Bilder herunterrechnet; Text und Vektoren bleiben erhalten (siehe `CompressionLevel.warning`).
    static func compress(_ url: URL, level: CompressionLevel, mode: OutputMode = .besideOriginal,
                         cacheDir: URL = Shelf.cacheDir) throws -> PDFCompressionResult {
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }

        guard let src = PDFDocument(url: url), !src.isLocked else { throw PDFToolsError.unreadable }
        guard src.pageCount > 0 else { throw PDFToolsError.nothingToSave }
        let originalSize = fileSize(url)

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        do {
            switch level {
            case .low, .medium:
                let doc = PDFDocument()
                for i in 0..<src.pageCount {
                    // Anmerkungen noch im Quelldokument laden, sonst zeigen interne Links danach auf Seite 1.
                    if let p = src.page(at: i) { _ = p.annotations; doc.insert(p, at: doc.pageCount) }
                }
                // Metadaten und Lesezeichen hängen am Dokument, nicht an den Seiten.
                doc.documentAttributes = src.documentAttributes
                doc.outlineRoot = src.outlineRoot
                var opts: [PDFDocumentWriteOption: Any] = [.saveImagesAsJPEGOption: true]
                if level == .medium { opts[.optimizeImagesForScreenOption] = true }
                guard doc.write(to: tmp, withOptions: opts) else { throw PDFToolsError.writeFailed }
            case .high:
                try drawFiltered(src, to: tmp)
            }
            let newSize = fileSize(tmp)
            guard newSize < originalSize else {
                try? FileManager.default.removeItem(at: tmp)
                return PDFCompressionResult(url: url, originalSize: originalSize, newSize: newSize, placement: nil)
            }
            let placed = try FileOutput.placeReporting(tmp, for: url, suffix: "komprimiert", ext: "pdf",
                                                       mode: mode, cacheDir: cacheDir)
            return PDFCompressionResult(url: placed.url, originalSize: originalSize, newSize: newSize, placement: placed)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
    }

    private static func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
    }

    /// Zeichnet alle Seiten (Crop-Box, Drehung angewandt) durch einen Bild-Reduzier-Filter in eine neue PDF.
    /// Werte wie Apples „Reduce File Size“-Filter, aber 100 dpi / Qualität 0,5.
    private static func drawFiltered(_ src: PDFDocument, to dest: URL) throws {
        let props: [String: Any] = [
            "Domains": ["Applications": true], "FilterType": 1, "Name": "DropShelf Stark",
            "FilterData": ["ColorSettings": ["ImageSettings": [
                "Compression Quality": 0.5, "ImageCompression": "ImageJPEGCompress",
                "ImageScaleSettings": ["ImageResolution": 100, "ImageScaleInterpolate": true,
                                       "ImageSizeMax": 1600, "ImageSizeMin": 0],
            ]]],
        ]
        guard let filter = QuartzFilter(properties: props),
              let ctx = CGContext(dest as CFURL, mediaBox: nil, nil) else { throw PDFToolsError.writeFailed }
        guard filter.apply(to: ctx) else { ctx.closePDF(); throw PDFToolsError.writeFailed }
        for i in 0..<src.pageCount {
            guard let page = src.page(at: i) else { continue }
            let crop = page.bounds(for: .cropBox)
            let turned = page.rotation % 180 != 0
            var box = CGRect(x: 0, y: 0, width: turned ? crop.height : crop.width,
                             height: turned ? crop.width : crop.height)
            let info = [kCGPDFContextMediaBox as String: Data(bytes: &box, count: MemoryLayout<CGRect>.size)]
            ctx.beginPDFPage(info as CFDictionary)
            page.draw(with: .cropBox, to: ctx)
            ctx.endPDFPage()
        }
        filter.remove(from: ctx)
        ctx.closePDF()
    }
}
