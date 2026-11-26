import Foundation
import AppKit
import CoreGraphics
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// Konverter mit PDF als Quelle: Seiten als PNG/JPEG rendern oder reinen Text in Textformate exportieren.
enum PDFConverter {
    static let defaultDPI: Double = 150
    static let textExtractionWarning = "Es wird nur der reine Text ohne Layout, Bilder oder Tabellen übernommen."

    static let writableImages: [UTType] = [.png, .jpeg]
    static let writableText: [UTType] = [.plainText, TextConverter.markdown, .rtf, TextConverter.docx, TextConverter.odt]
    static let writable: [UTType] = writableImages + writableText

    /// Liest eine DPI-Angabe aus `ConvertOptions.preset` (z. B. `"dpi:200"` oder `"200"`),
    /// begrenzt auf `36...600`; fehlt oder ist ungültig → `defaultDPI` (150).
    static func parseDPI(_ preset: String?) -> Double {
        guard let raw = preset?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return defaultDPI
        }
        let numStr: String
        if raw.lowercased().hasPrefix("dpi:") {
            numStr = String(raw.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            numStr = raw
        }
        guard let value = Double(numStr), value.isFinite else { return defaultDPI }
        return min(max(value, 36), 600)
    }

    static var converter: Converter {
        let pairs = Set(writable.map { Conversion(from: .pdf, to: $0) })
        return Converter(id: "pdf", pairs: pairs) { src, dst, o in
            try await convert(src, dst, o)
        }
    }

    /// Exportiert alle Seiten einer PDF als Einzelbilder in einen neuen Ordner (`<Name> (Seiten)`),
    /// abgelegt über `FileOutput`, und gibt die sortierten Bild-URLs zurück.
    static func exportPages(_ url: URL, to format: UTType, options: ConvertOptions = ConvertOptions(),
                            mode: OutputMode = .besideOriginal, cacheDir: URL = Shelf.cacheDir) throws -> [URL] {
        guard writableImages.contains(format) else { throw ConvertError.unsupported }
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }

        guard let doc = PDFDocument(url: url), !doc.isLocked, doc.pageCount > 0 else {
            throw ConvertError.unreadable
        }

        let tmpFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("dropshelf-pdf-pages-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpFolder, withIntermediateDirectories: true)
        do {
            try renderAllPages(of: doc, into: tmpFolder, format: format, options: options)
            let placed = try FileOutput.place(tmpFolder, for: url, suffix: "Seiten", ext: "",
                                              mode: mode, cacheDir: cacheDir)
            let files = try FileManager.default.contentsOfDirectory(
                at: placed,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            return files.sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch {
            try? FileManager.default.removeItem(at: tmpFolder)
            throw error
        }
    }

    // MARK: Intern

    private static func convert(_ src: URL, _ dst: URL, _ o: ConvertOptions) async throws {
        guard let to = UTType(filenameExtension: dst.pathExtension) else { throw ConvertError.unsupported }
        if writableImages.contains(to) {
            try renderToImages(src, dst: dst, format: to, options: o)
        } else if writableText.contains(to) {
            let text = try readPlainText(from: src)
            try await MainActor.run { try writeText(text, to: dst, format: to) }
        } else {
            throw ConvertError.unsupported
        }
    }

    private static func renderToImages(_ src: URL, dst: URL, format: UTType, options o: ConvertOptions) throws {
        let started = src.startAccessingSecurityScopedResource()
        defer { if started { src.stopAccessingSecurityScopedResource() } }

        guard let doc = PDFDocument(url: src), !doc.isLocked, doc.pageCount > 0 else {
            throw ConvertError.unreadable
        }

        if doc.pageCount == 1 {
            guard let page = doc.page(at: 0) else { throw ConvertError.unreadable }
            let image = try renderPage(page, options: o)
            try writeImage(image, to: dst, format: format, quality: o.quality)
        } else {
            try FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true)
            try renderAllPages(of: doc, into: dst, format: format, options: o)
        }
    }

    private static func renderAllPages(of doc: PDFDocument, into dir: URL,
                                       format: UTType, options o: ConvertOptions) throws {
        let ext = format.preferredFilenameExtension ?? (format == .jpeg ? "jpg" : "png")
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let image = try renderPage(page, options: o)
            let name = String(format: "Seite-%03d.%@", i + 1, ext)
            try writeImage(image, to: dir.appendingPathComponent(name), format: format, quality: o.quality)
        }
    }

    private static func renderPage(_ page: PDFPage, options o: ConvertOptions) throws -> CGImage {
        let crop = page.bounds(for: .cropBox)
        let turned = page.rotation % 180 != 0
        let pageW = turned ? crop.height : crop.width
        let pageH = turned ? crop.width : crop.height
        guard pageW > 0, pageH > 0 else { throw ConvertError.unreadable }

        let dpiScale = CGFloat(parseDPI(o.preset) / 72.0)
        let baseSize = CGSize(width: max(1, (pageW * dpiScale).rounded()),
                              height: max(1, (pageH * dpiScale).rounded()))
        let finalSize = targetSize(baseSize, o.imageScale)
        let pxW = max(1, Int(finalSize.width.rounded()))
        let pxH = max(1, Int(finalSize.height.rounded()))

        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: pxW, height: pxH, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw ConvertError.writeFailed }

        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: pxW, height: pxH))
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: CGFloat(pxW) / pageW, y: CGFloat(pxH) / pageH)
        page.draw(with: .cropBox, to: ctx)

        guard let image = ctx.makeImage() else { throw ConvertError.writeFailed }
        return image
    }

    private static func writeImage(_ image: CGImage, to dst: URL, format: UTType, quality: Double?) throws {
        guard let dest = CGImageDestinationCreateWithURL(dst as CFURL, format.identifier as CFString, 1, nil) else {
            throw ConvertError.writeFailed
        }
        var opts: [CFString: Any] = [:]
        if format == .jpeg, let q = quality {
            opts[kCGImageDestinationLossyCompressionQuality] = min(max(q, 0), 1)
        }
        CGImageDestinationAddImage(dest, image, opts as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ConvertError.writeFailed }
    }

    private static func readPlainText(from src: URL) throws -> String {
        let started = src.startAccessingSecurityScopedResource()
        defer { if started { src.stopAccessingSecurityScopedResource() } }

        guard let doc = PDFDocument(url: src), !doc.isLocked, doc.pageCount > 0 else {
            throw ConvertError.unreadable
        }
        return doc.string ?? ""
    }

    @MainActor
    private static func writeText(_ text: String, to dst: URL, format: UTType) throws {
        if format == .plainText || format == TextConverter.markdown {
            try Data(text.utf8).write(to: dst)
            return
        }
        let docType: NSAttributedString.DocumentType
        switch format {
        case .rtf: docType = .rtf
        case TextConverter.docx: docType = .officeOpenXML
        case TextConverter.odt: docType = .openDocument
        default: throw ConvertError.unsupported
        }
        let attr = NSAttributedString(string: text)
        let range = NSRange(location: 0, length: attr.length)
        guard let data = try? attr.data(from: range, documentAttributes: [.documentType: docType]) else {
            throw ConvertError.writeFailed
        }
        try data.write(to: dst)
    }
}
