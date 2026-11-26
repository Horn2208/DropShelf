import Foundation
import AppKit
import UniformTypeIdentifiers

struct Conversion: Hashable, Sendable { let from: UTType; let to: UTType }

struct ConvertOptions: Sendable {
    var imageScale: ImageScale = .original
    var quality: Double? = nil
    var preset: String? = nil
}

/// `run(quelle, ziel-tmp, optionen)` schreibt das Ergebnis nach `ziel-tmp`.
struct Converter: Sendable {
    let id: String
    let pairs: Set<Conversion>
    let run: @Sendable (URL, URL, ConvertOptions) async throws -> Void
}

enum ConvertError: LocalizedError {
    case unsupported, unreadable, writeFailed, heicUnavailable
    case unsupportedContainer(String)
    var errorDescription: String? {
        switch self {
        case .unsupported: return "Diese Umwandlung wird nicht unterstützt."
        case .unreadable: return "Die Datei konnte nicht gelesen werden."
        case .writeFailed: return "Das Ergebnis konnte nicht geschrieben werden."
        case .heicUnavailable: return "HEIC kann auf diesem Mac nicht geschrieben werden (kein HEVC-Encoder)."
        case .unsupportedContainer(let ext):
            return "Das Videoformat „\(ext)“ kann auf diesem Mac von AVFoundation nicht geöffnet werden."
        }
    }
}

enum ConverterRegistry {
    static let builtIn: [Converter] = [
        TextConverter.converter,
        ImageConverter.converter,
        AudioConverter.converter,
        VideoConverter.converter,
        PDFConverter.converter,
        FontConverter.converter,
    ]

    static func targets(for type: UTType) -> [UTType] {
        let all = builtIn.flatMap(\.pairs).filter { $0.from == type }.map(\.to)
        return Array(Set(all)).sorted { $0.identifier < $1.identifier }
    }

    static func converter(for c: Conversion) -> Converter? { builtIn.first { $0.pairs.contains(c) } }

    @discardableResult
    static func convert(_ url: URL, to: UTType, _ o: ConvertOptions = ConvertOptions(),
                        mode: OutputMode = .besideOriginal, cacheDir: URL = Shelf.cacheDir) async throws -> URL {
        try await convertReporting(url, to: to, o, mode: mode, cacheDir: cacheDir).url
    }

    /// Wie `convert`, meldet aber, ob mangels Schreibrecht in den Cache ausgewichen wurde (`inCache`/`notice`).
    static func convertReporting(_ url: URL, to: UTType, _ o: ConvertOptions = ConvertOptions(),
                                 mode: OutputMode = .besideOriginal, cacheDir: URL = Shelf.cacheDir) async throws -> FileOutput.Placement {
        guard let from = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
                ?? UTType(filenameExtension: url.pathExtension),
              let conv = Self.converter(for: Conversion(from: from, to: to)) ?? Self.converter(forExtensionOf: url, to: to)
        else {
            let ext = url.pathExtension.lowercased()
            if VideoConverter.knownUnsupportedContainerExtensions.contains(ext) {
                throw ConvertError.unsupportedContainer(ext.uppercased())
            }
            throw ConvertError.unsupported
        }
        let ext = to.preferredFilenameExtension ?? ""
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("dropshelf-convert-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let out = tmpDir.appendingPathComponent("out" + (ext.isEmpty ? "" : "." + ext))
        try await conv.run(url, out, o)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: out.path, isDirectory: &isDir), isDir.boolValue {
            let dirSuffix = conv.id == "font" ? "Schriften" : "Seiten"
            return try FileOutput.placeReporting(out, for: url, suffix: dirSuffix, ext: "", mode: mode, cacheDir: cacheDir)
        }
        return try FileOutput.placeReporting(out, for: url, suffix: "", ext: ext, mode: mode, cacheDir: cacheDir)
    }

    /// Rückfall, falls das Dateisystem den Typ nicht (z. B. „md“) erkennt: nach Endung suchen.
    private static func converter(forExtensionOf url: URL, to: UTType) -> Converter? {
        UTType(filenameExtension: url.pathExtension).flatMap { converter(for: Conversion(from: $0, to: to)) }
    }
}

// MARK: Text über NSAttributedString

enum TextConverter {
    static let markdown = UTType("net.daringfireball.markdown") ?? UTType(filenameExtension: "md")!
    static let doc = UTType("com.microsoft.word.doc")!
    static let docx = UTType("org.openxmlformats.wordprocessingml.document")!
    static let odt = UTType("org.oasis-open.opendocument.text")!

    static let readable: [UTType] = [.plainText, markdown, .rtf, .rtfd, .html, doc, docx, odt, .webArchive]
    static let writable: [UTType] = [.plainText, markdown, .rtf, .rtfd, .html, doc, docx, odt, .pdf]

    static var converter: Converter {
        let pairs = Set(readable.flatMap { f in writable.filter { $0 != f }.map { Conversion(from: f, to: $0) } })
        return Converter(id: "text", pairs: pairs) { src, dst, _ in
            try await MainActor.run { try convert(src, dst) }
        }
    }

    private static func docType(_ t: UTType) -> NSAttributedString.DocumentType? {
        switch t {
        case .rtf: return .rtf
        case .rtfd: return .rtfd
        case .html: return .html
        case .webArchive: return .webArchive
        case doc: return .docFormat
        case docx: return .officeOpenXML
        case odt: return .openDocument
        default: return nil
        }
    }

    @MainActor
    private static func convert(_ src: URL, _ dst: URL) throws {
        guard let from = UTType(filenameExtension: src.pathExtension),
              let to = UTType(filenameExtension: dst.pathExtension) else { throw ConvertError.unsupported }
        let text = try read(src, as: from)
        let range = NSRange(location: 0, length: text.length)
        if to == .plainText {
            try Data(text.string.utf8).write(to: dst)
        } else if to == markdown {
            try Data(markdownString(text).utf8).write(to: dst)
        } else if to == .pdf {
            try writePDF(text, to: dst)
        } else if to == .rtfd {
            guard let w = text.rtfd(from: range, documentAttributes: [:]) else { throw ConvertError.writeFailed }
            try w.write(to: dst)
        } else if let t = docType(to), let data = try? text.data(from: range, documentAttributes: [.documentType: t]) {
            try data.write(to: dst)
        } else { throw ConvertError.writeFailed }
    }

    /// Mehrseitiges PDF (A4, 2 cm Rand) per NSLayoutManager ohne Fenster und ohne Drucksystem.
    /// Bewusst nicht `NSPrintOperation`: deren `run()` läuft modal auf dem Main-Thread über das Drucksystem
    /// und kann hostless (Tests, Sandbox) hängen.
    /// Erhält Textfarben, Hintergrundfarben, klickbare PDF-Links (`.link`) und eingebettete Bilder (`NSTextAttachment`).
    @MainActor
    static func writePDF(_ text: NSAttributedString, to dst: URL) throws {
        var page = CGRect(x: 0, y: 0, width: 595.28, height: 841.89)
        let margin: CGFloat = 56.7
        let contentSize = CGSize(width: page.width - 2 * margin, height: page.height - 2 * margin)
        guard let ctx = CGContext(dst as CFURL, mediaBox: &page, nil) else { throw ConvertError.writeFailed }

        let storage = NSTextStorage(attributedString: text)
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)

        var wroteAnyPage = false
        while true {
            let container = NSTextContainer(size: contentSize)
            container.lineFragmentPadding = 0
            layoutManager.addTextContainer(container)

            let glyphRange = layoutManager.glyphRange(for: container)
            if glyphRange.length == 0 {
                if !wroteAnyPage {
                    ctx.beginPDFPage(nil)
                    ctx.endPDFPage()
                }
                break
            }
            wroteAnyPage = true

            ctx.beginPDFPage(nil)
            ctx.saveGState()
            ctx.translateBy(x: 0, y: page.height)
            ctx.scaleBy(x: 1, y: -1)

            let origin = CGPoint(x: margin, y: margin)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            layoutManager.drawBackground(forGlyphRange: glyphRange, at: origin)
            layoutManager.drawGlyphs(forGlyphRange: glyphRange, at: origin)
            NSGraphicsContext.restoreGraphicsState()
            ctx.restoreGState()

            let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            storage.enumerateAttribute(.link, in: charRange) { value, range, _ in
                guard let url = (value as? URL) ?? (value as? String).flatMap(URL.init(string:)) else { return }
                let linkGlyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                layoutManager.enumerateEnclosingRects(
                    forGlyphRange: linkGlyphs,
                    withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                    in: container
                ) { rect, _ in
                    let pdfRect = CGRect(
                        x: margin + rect.origin.x,
                        y: page.height - margin - rect.maxY,
                        width: rect.width,
                        height: rect.height
                    )
                    ctx.setURL(url as CFURL, for: pdfRect)
                }
            }

            ctx.endPDFPage()
            if NSMaxRange(glyphRange) >= layoutManager.numberOfGlyphs { break }
        }
        ctx.closePDF()
    }

    @MainActor
    private static func read(_ url: URL, as type: UTType) throws -> NSAttributedString {
        if type == .plainText { return NSAttributedString(string: try String(contentsOf: url, encoding: .utf8)) }
        // ponytail: Markdown nur Inline-Stil (fett/kursiv/Code/Links); Überschriften/Listen bleiben Rohtext (16.2).
        if type == markdown { return try markdownText(String(contentsOf: url, encoding: .utf8)) }
        guard let t = docType(type) else { throw ConvertError.unsupported }
        return try NSAttributedString(url: url, options: [.documentType: t], documentAttributes: nil)
    }

    private static func markdownText(_ md: String) throws -> NSAttributedString {
        let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let attr = try AttributedString(markdown: md, options: opts)
        let out = NSMutableAttributedString()
        let base = NSFont.systemFont(ofSize: 13)
        for run in attr.runs {
            var font = base
            let i = run.inlinePresentationIntent ?? []
            var traits: NSFontDescriptor.SymbolicTraits = []
            if i.contains(.stronglyEmphasized) { traits.insert(.bold) }
            if i.contains(.emphasized) { traits.insert(.italic) }
            if i.contains(.code) { font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular) }
            if !traits.isEmpty { font = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(traits), size: 13) ?? font }
            var a: [NSAttributedString.Key: Any] = [.font: font]
            if let l = run.link { a[.link] = l }
            out.append(NSAttributedString(string: String(attr[run.range].characters), attributes: a))
        }
        return out
    }

    /// Kleiner Markdown-Writer: fett/kursiv/Code/Links, Überschriften nur aus der Schriftgröße je Zeile.
    /// ponytail: kein Escaping von Sonderzeichen, keine Listen/Tabellen; bei Bedarf hier erweitern.
    static func markdownString(_ text: NSAttributedString) -> String {
        let ns = text.string as NSString
        var out = ""
        var loc = 0
        while loc < ns.length {
            let line = ns.lineRange(for: NSRange(location: loc, length: 0))
            loc = NSMaxRange(line)
            let body = NSRange(location: line.location, length: line.length - (ns.substring(with: line).hasSuffix("\n") ? 1 : 0))
            var maxSize: CGFloat = 0
            var md = ""
            text.enumerateAttributes(in: body) { a, r, _ in
                let font = a[.font] as? NSFont
                maxSize = max(maxSize, font?.pointSize ?? 0)
                md += styled(ns.substring(with: r), font, a[.link], heading: false)
            }
            let level = maxSize >= 22 ? 1 : maxSize >= 18 ? 2 : maxSize >= 15 ? 3 : 0
            if level > 0 {  // Überschrift: Fett-Markierung weglassen
                md = ""
                text.enumerateAttributes(in: body) { a, r, _ in
                    md += styled(ns.substring(with: r), a[.font] as? NSFont, a[.link], heading: true)
                }
                md = String(repeating: "#", count: level) + " " + md
            }
            out += md + (line.length > body.length ? "\n" : "")
        }
        return out
    }

    private static func styled(_ s: String, _ font: NSFont?, _ link: Any?, heading: Bool) -> String {
        let core = s.trimmingCharacters(in: .whitespaces)
        guard !core.isEmpty else { return s }
        let lead = String(s.prefix { $0 == " " || $0 == "\t" })
        let trail = String(s.reversed().prefix { $0 == " " || $0 == "\t" }.reversed())
        var t = core
        let traits = font?.fontDescriptor.symbolicTraits ?? []
        if font?.isFixedPitch == true { t = "`\(t)`" }
        else {
            if traits.contains(.italic) { t = "*\(t)*" }
            if traits.contains(.bold) && !heading { t = "**\(t)**" }
        }
        if let l = link as? URL ?? (link as? String).flatMap(URL.init(string:)) { t = "[\(t)](\(l.absoluteString))" }
        return lead + t + trail
    }
}
