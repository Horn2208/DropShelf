import XCTest
import AppKit
import CoreGraphics
import CoreText
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// Hostless: nur eigener Temp-Ordner; `cacheDir` zeigt nie auf den echten Cache.
final class PDFConverterTests: XCTestCase {
    private var tmp: URL!
    private var cache: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        tmp = fm.temporaryDirectory.appendingPathComponent("dropshelf-pdfconv-" + UUID().uuidString)
        cache = tmp.appendingPathComponent("cache")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: tmp)
    }

    private func makePDF(_ name: String = "Dokument.pdf",
                         pages: [String] = ["Seite Eins Hallo", "Seite Zwei Welt", "Seite Drei Ende"],
                         pageSize: CGSize = CGSize(width: 200, height: 300)) throws -> URL {
        let url = tmp.appendingPathComponent(name)
        var box = CGRect(origin: .zero, size: pageSize)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else {
            throw XCTSkip("CGContext PDF konnte nicht erzeugt werden")
        }
        let textPath = CGPath(rect: box.insetBy(dx: 16, dy: 16), transform: nil)
        let font = CTFontCreateWithName("Helvetica" as CFString, 14, nil)
        for text in pages {
            ctx.beginPDFPage(nil)
            let attr = NSAttributedString(string: text, attributes: [.font: font])
            let setter = CTFramesetterCreateWithAttributedString(attr)
            let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: attr.length), textPath, nil)
            CTFrameDraw(frame, ctx)
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return url
    }

    private func imageType(_ url: URL) -> String? {
        CGImageSourceCreateWithURL(url as CFURL, nil).flatMap(CGImageSourceGetType) as String?
    }

    private func imagePixelSize(_ url: URL) -> (width: Int, height: Int)? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (w, h)
    }

    func testTargetsForPDF() {
        let targets = ConverterRegistry.targets(for: .pdf)
        for expected in [UTType.png, .jpeg, .plainText, TextConverter.markdown, .rtf, TextConverter.docx, TextConverter.odt] {
            XCTAssertTrue(targets.contains(expected), "Fehlendes Zielformat für PDF: \(expected.identifier)")
        }
        XCTAssertFalse(targets.contains(.pdf))
    }

    func testParseDPI() {
        XCTAssertEqual(PDFConverter.parseDPI(nil), 150)
        XCTAssertEqual(PDFConverter.parseDPI(""), 150)
        XCTAssertEqual(PDFConverter.parseDPI("invalid"), 150)
        XCTAssertEqual(PDFConverter.parseDPI("dpi:300"), 300)
        XCTAssertEqual(PDFConverter.parseDPI("DPI:200"), 200)
        XCTAssertEqual(PDFConverter.parseDPI("72"), 72)
        XCTAssertEqual(PDFConverter.parseDPI("dpi:10"), 36)
        XCTAssertEqual(PDFConverter.parseDPI("1200"), 600)
    }

    func testExportPagesToPNGAndDPIScaling() throws {
        let pdf = try makePDF("Mehrseitig.pdf", pageSize: CGSize(width: 200, height: 300))

        var opts72 = ConvertOptions()
        opts72.preset = "dpi:72"
        let pages72 = try PDFConverter.exportPages(pdf, to: .png, options: opts72, mode: .cache, cacheDir: cache)
        XCTAssertEqual(pages72.count, 3)
        for pageURL in pages72 {
            XCTAssertEqual(imageType(pageURL), UTType.png.identifier)
        }
        let size72 = try XCTUnwrap(imagePixelSize(pages72[0]))
        XCTAssertEqual(size72.width, 200)
        XCTAssertEqual(size72.height, 300)

        var opts144 = ConvertOptions()
        opts144.preset = "dpi:144"
        let pages144 = try PDFConverter.exportPages(pdf, to: .png, options: opts144, mode: .cache, cacheDir: cache)
        XCTAssertEqual(pages144.count, 3)
        let size144 = try XCTUnwrap(imagePixelSize(pages144[0]))
        XCTAssertEqual(size144.width, 400)
        XCTAssertEqual(size144.height, 600)
    }

    func testExportPagesToJPEG() throws {
        let pdf = try makePDF("Fotos.pdf")
        var opts = ConvertOptions()
        opts.quality = 0.85
        opts.preset = "150"
        let pages = try PDFConverter.exportPages(pdf, to: .jpeg, options: opts, mode: .cache, cacheDir: cache)
        XCTAssertEqual(pages.count, 3)
        for (idx, pageURL) in pages.enumerated() {
            XCTAssertEqual(imageType(pageURL), UTType.jpeg.identifier)
            XCTAssertTrue(pageURL.lastPathComponent.hasPrefix(String(format: "Seite-%03d.", idx + 1)))
        }
    }

    func testSinglePagePDFToPNGViaRegistry() async throws {
        let pdf = try makePDF("Einzel.pdf", pages: ["Nur eine Seite"], pageSize: CGSize(width: 144, height: 144))
        var opts = ConvertOptions()
        opts.preset = "dpi:72"
        let out = try await ConverterRegistry.convert(pdf, to: .png, opts, mode: .cache, cacheDir: cache)
        XCTAssertEqual(imageType(out), UTType.png.identifier)
        let size = try XCTUnwrap(imagePixelSize(out))
        XCTAssertEqual(size.width, 144)
        XCTAssertEqual(size.height, 144)
    }

    func testPDFToTextFormatsViaRegistry() async throws {
        let pdf = try makePDF("Textquelle.pdf")

        // Plain Text & Markdown
        for format in [UTType.plainText, TextConverter.markdown] {
            let out = try await ConverterRegistry.convert(pdf, to: format, mode: .cache, cacheDir: cache)
            let content = try String(contentsOf: out, encoding: .utf8)
            XCTAssertTrue(content.contains("Seite Eins Hallo"), "\(format.identifier): \(content)")
            XCTAssertTrue(content.contains("Seite Drei Ende"), "\(format.identifier): \(content)")
        }

        // RTF, DOCX, ODT
        for format in [UTType.rtf, TextConverter.docx, TextConverter.odt] {
            let out = try await ConverterRegistry.convert(pdf, to: format, mode: .cache, cacheDir: cache)
            let extracted = try await MainActor.run { () -> String in
                let docType: NSAttributedString.DocumentType
                switch format {
                case .rtf: docType = .rtf
                case TextConverter.docx: docType = .officeOpenXML
                case TextConverter.odt: docType = .openDocument
                default: return ""
                }
                return try NSAttributedString(url: out, options: [.documentType: docType], documentAttributes: nil).string
            }
            XCTAssertTrue(extracted.contains("Seite Eins Hallo"), "\(format.identifier): \(extracted)")
            XCTAssertTrue(extracted.contains("Seite Drei Ende"), "\(format.identifier): \(extracted)")
        }
    }

    func testUnreadablePDFThrows() async throws {
        let broken = tmp.appendingPathComponent("Kaputt.pdf")
        try Data("kein echtes pdf".utf8).write(to: broken)
        do {
            _ = try await ConverterRegistry.convert(broken, to: .plainText, mode: .cache, cacheDir: cache)
            XCTFail("Erwartete ConvertError.unreadable")
        } catch ConvertError.unreadable {
            // erwartet
        }
    }
}
