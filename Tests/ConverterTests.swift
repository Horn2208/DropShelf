import XCTest
import UniformTypeIdentifiers
import PDFKit

/// Hostless: nur eigener Temp-Ordner; `cacheDir` zeigt nie auf den echten Cache.
final class ConverterTests: XCTestCase {
    private var tmp: URL!
    private var cache: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        tmp = fm.temporaryDirectory.appendingPathComponent("dropshelf-converter-" + UUID().uuidString)
        cache = tmp.appendingPathComponent("cache")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? fm.removeItem(at: tmp) }

    private func write(_ name: String, _ s: String) throws -> URL {
        let u = tmp.appendingPathComponent(name)
        try Data(s.utf8).write(to: u)
        return u
    }

    func testTextRoundTripKeepsText() async throws {
        let txt = try write("Brief.txt", "Hallo Welt\nZweite Zeile")
        let rtf = try await ConverterRegistry.convert(txt, to: .rtf, mode: .besideOriginal, cacheDir: cache)
        let docx = try await ConverterRegistry.convert(rtf, to: TextConverter.docx, mode: .besideOriginal, cacheDir: cache)
        let back = try await ConverterRegistry.convert(docx, to: .plainText, mode: .besideOriginal, cacheDir: cache)
        let s = try String(contentsOf: back, encoding: .utf8)
        XCTAssertTrue(s.contains("Hallo Welt"), s)
        XCTAssertTrue(s.contains("Zweite Zeile"), s)
    }

    func testTargetsForPlainText() {
        let t = ConverterRegistry.targets(for: .plainText)
        XCTAssertTrue(t.contains(TextConverter.docx))
        XCTAssertFalse(t.contains(.plainText))
        XCTAssertFalse(t.contains(.webArchive))
        XCTAssertTrue(ConverterRegistry.targets(for: .gif).contains(.png))  // Bild-Konverter ist eingehängt
    }

    func testMarkdownBoldToHTML() async throws {
        let md = try write("Notiz.md", "Das ist **fett** und *schief*.")
        let html = try await ConverterRegistry.convert(md, to: .html, mode: .besideOriginal, cacheDir: cache)
        let s = try String(contentsOf: html, encoding: .utf8).lowercased()
        XCTAssertTrue(s.contains("<b>") || s.contains("<strong>"), s)
    }
}

extension ConverterTests {
    func testMarkdownRoundTripViaRTF() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dropshelf-mdw-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = dir.appendingPathComponent("cache")
        let md = dir.appendingPathComponent("Notiz.md")
        try Data("a **fett** b *kursiv* c [Text](https://example.com/x)".utf8).write(to: md)
        let rtf = try await ConverterRegistry.convert(md, to: .rtf, mode: .besideOriginal, cacheDir: cache)
        try? FileManager.default.removeItem(at: md)
        let back = try await ConverterRegistry.convert(rtf, to: TextConverter.markdown, mode: .besideOriginal, cacheDir: cache)
        let s = try String(contentsOf: back, encoding: .utf8)
        XCTAssertTrue(s.contains("**fett**"), s)
        XCTAssertTrue(s.contains("*kursiv*"), s)
        XCTAssertTrue(s.contains("[Text](https://example.com/x)"), s)
        XCTAssertTrue(ConverterRegistry.targets(for: .rtf).contains(TextConverter.markdown))
        XCTAssertFalse(ConverterRegistry.targets(for: TextConverter.markdown).contains(TextConverter.markdown))
    }

    func testLongTextToMultiPagePDF() async throws {
        let lines = (1...300).map { "Zeile \($0) mit etwas Text" }.joined(separator: "\n")
        let txt = try write("Lang.txt", lines + "\nENDMARKE")
        let pdf = try await ConverterRegistry.convert(txt, to: .pdf, mode: .besideOriginal, cacheDir: cache)
        let doc = try XCTUnwrap(PDFDocument(url: pdf))
        XCTAssertGreaterThan(doc.pageCount, 1)
        let s = doc.string ?? ""
        XCTAssertTrue(s.contains("Zeile 1 mit"), s)
        XCTAssertTrue(s.contains("ENDMARKE"), s)
        XCTAssertEqual(doc.page(at: 0)?.bounds(for: .mediaBox).width ?? 0, 595.28, accuracy: 1)  // A4
        for t in TextConverter.readable { XCTAssertTrue(ConverterRegistry.targets(for: t).contains(.pdf), t.identifier) }
    }

    @MainActor
    func testTextToPDFPreservesColorsLinksAndEmbeddedImages() throws {
        let attr = NSMutableAttributedString()
        attr.append(NSAttributedString(string: "Roter Text ", attributes: [
            .font: NSFont.boldSystemFont(ofSize: 28),
            .foregroundColor: NSColor(calibratedRed: 1, green: 0, blue: 0, alpha: 1),
        ]))
        let linkURL = URL(string: "https://example.com/dropshelf")!
        attr.append(NSAttributedString(string: "KlickLink\n", attributes: [
            .font: NSFont.systemFont(ofSize: 18),
            .link: linkURL,
        ]))

        // Eingebettetes grünes Bild (40x40)
        let img = NSImage(size: NSSize(width: 40, height: 40), flipped: false) { rect in
            NSColor(calibratedRed: 0, green: 0.9, blue: 0, alpha: 1).setFill()
            rect.fill()
            return true
        }
        let attachment = NSTextAttachment()
        attachment.image = img
        attachment.bounds = CGRect(x: 0, y: 0, width: 40, height: 40)
        attr.append(NSAttributedString(attachment: attachment))

        let pdfURL = tmp.appendingPathComponent("Rich.pdf")
        try TextConverter.writePDF(attr, to: pdfURL)

        let doc = try XCTUnwrap(PDFDocument(url: pdfURL))
        XCTAssertEqual(doc.pageCount, 1)
        let page = try XCTUnwrap(doc.page(at: 0))

        // Link-Annotation prüfen
        let urls = page.annotations.compactMap { $0.url }
        XCTAssertTrue(urls.contains(linkURL), "Link-Annotation fehlt: \(urls)")

        // Seite rendern und prüfen, ob sowohl rote Textpixel als auch grüne Bildpixel vorhanden sind
        let w = 595, h = 842
        var rgba = [UInt8](repeating: 255, count: w * h * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        rgba.withUnsafeMutableBytes { buf in
            let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            page.draw(with: .mediaBox, to: ctx)
        }
        var hasRed = false
        var hasGreen = false
        for i in stride(from: 0, to: rgba.count, by: 4) {
            let r = rgba[i], g = rgba[i + 1], b = rgba[i + 2]
            if r > 180 && g < 60 && b < 60 { hasRed = true }
            if g > 180 && r < 60 && b < 60 { hasGreen = true }
            if hasRed && hasGreen { break }
        }
        XCTAssertTrue(hasRed, "Farbiger (roter) Text sollte im PDF sichtbar sein")
        XCTAssertTrue(hasGreen, "Eingebettetes (grünes) Bild sollte im PDF sichtbar sein")
    }
}
