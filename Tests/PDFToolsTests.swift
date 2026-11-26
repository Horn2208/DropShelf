import XCTest
import PDFKit
import CoreText
import ImageIO
import UniformTypeIdentifiers

/// Hostless: nur eigener Temp-Ordner; `cacheDir` zeigt nie auf den echten Cache.
final class PDFToolsTests: XCTestCase {
    private var tmp: URL!
    private var cache: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        tmp = fm.temporaryDirectory.appendingPathComponent("dropshelf-pdftools-" + UUID().uuidString)
        cache = tmp.appendingPathComponent("cache")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? fm.removeItem(at: tmp) }

    /// PDF mit je einer Seite pro Text (Seite über eingebetteten Text erkennbar).
    private func makePDF(_ name: String, pages: [String]) throws -> URL {
        let url = tmp.appendingPathComponent(name)
        var box = CGRect(x: 0, y: 0, width: 300, height: 200)
        let ctx = CGContext(url as CFURL, mediaBox: &box, nil)!
        for text in pages {
            ctx.beginPDFPage(nil)
            let attr = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 24)])
            ctx.textPosition = CGPoint(x: 20, y: 100)
            CTLineDraw(CTLineCreateWithAttributedString(attr), ctx)
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return url
    }

    private func makePNG(_ name: String) throws -> URL {
        let cg = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                           space: CGColorSpaceCreateDeviceRGB(),
                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        let url = tmp.appendingPathComponent(name)
        let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(d, cg, nil)
        XCTAssertTrue(CGImageDestinationFinalize(d))
        return url
    }

    func testMergeOrderAndSkipped() throws {
        let a = try makePDF("a.pdf", pages: ["A1"])
        let img = try makePNG("b.png")
        let txt = tmp.appendingPathComponent("c.txt"); try Data("x".utf8).write(to: txt)
        let c = try makePDF("c.pdf", pages: ["C1", "C2"])

        let r = try PDFTools.merge([a, img, txt, c], cacheDir: cache)
        XCTAssertEqual(r.skipped, [txt])
        XCTAssertTrue(r.url.lastPathComponent.contains("zusammengefügt"))
        XCTAssertEqual(r.url.pathExtension, "pdf")
        XCTAssertEqual(r.url.deletingLastPathComponent().standardizedFileURL, tmp.standardizedFileURL)

        let doc = try XCTUnwrap(PDFDocument(url: r.url))
        XCTAssertEqual(doc.pageCount, 4)
        XCTAssertTrue(doc.page(at: 0)?.string?.contains("A1") == true)
        XCTAssertTrue((doc.page(at: 1)?.string ?? "").isEmpty)   // Bildseite ohne Text
        XCTAssertTrue(doc.page(at: 2)?.string?.contains("C1") == true)
        XCTAssertTrue(doc.page(at: 3)?.string?.contains("C2") == true)
        // Eingaben unverändert
        XCTAssertEqual(PDFDocument(url: a)?.pageCount, 1)
    }

    // MARK: 14.2

    private func openDoc(_ pages: [String]) throws -> PDFDocument {
        try XCTUnwrap(PDFDocument(url: makePDF("p-\(UUID().uuidString).pdf", pages: pages)))
    }

    private func texts(_ d: PDFDocument) -> [String] {
        (0..<d.pageCount).map { (d.page(at: $0)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    func testRotate() throws {
        let d = try openDoc(["A", "B"])
        XCTAssertEqual(d.page(at: 0)?.rotation, 0)
        PDFTools.rotate(page: 0, by: 90, in: d)
        XCTAssertEqual(d.page(at: 0)?.rotation, 90)
        PDFTools.rotate(page: 0, by: 90, in: d)
        XCTAssertEqual(d.page(at: 0)?.rotation, 180)
        PDFTools.rotate(page: 0, by: -270, in: d)
        XCTAssertEqual(d.page(at: 0)?.rotation, 270)
        PDFTools.rotate(page: 0, by: 90, in: d)
        XCTAssertEqual(d.page(at: 0)?.rotation, 0)
        PDFTools.rotate(page: 1, by: -90, in: d)
        XCTAssertEqual(d.page(at: 1)?.rotation, 270)
    }

    func testDeleteAndMove() throws {
        let d = try openDoc(["A", "B", "C", "D"])
        XCTAssertEqual(PDFTools.delete(pages: [1, 3], in: d), 2)
        XCTAssertEqual(texts(d), ["A", "C"])

        let m = try openDoc(["A", "B", "C", "D"])
        XCTAssertTrue(PDFTools.move(from: 0, to: 2, in: m))
        XCTAssertEqual(texts(m), ["B", "C", "A", "D"])
        XCTAssertTrue(PDFTools.move(from: 3, to: 0, in: m))
        XCTAssertEqual(texts(m), ["D", "B", "C", "A"])
        XCTAssertTrue(PDFTools.move(from: 0, to: 99, in: m))   // wird auf das Ende begrenzt
        XCTAssertEqual(texts(m), ["B", "C", "A", "D"])
    }

    func testExtractKeepsOriginal() throws {
        let d = try openDoc(["A", "B", "C"])
        let e = PDFTools.extract(pages: [2, 0], from: d)
        XCTAssertEqual(texts(e), ["C", "A"])
        XCTAssertEqual(texts(d), ["A", "B", "C"])
        PDFTools.rotate(page: 0, by: 90, in: e)
        XCTAssertEqual(d.page(at: 2)?.rotation, 0)
    }

    func testInvalidIndicesDoNotCrash() throws {
        let d = try openDoc(["A", "B"])
        XCTAssertFalse(PDFTools.rotate(page: 5, by: 90, in: d))
        XCTAssertFalse(PDFTools.rotate(page: -1, by: 90, in: d))
        XCTAssertEqual(PDFTools.delete(pages: [-1, 7], in: d), 0)
        XCTAssertFalse(PDFTools.move(from: 9, to: 0, in: d))
        XCTAssertFalse(PDFTools.move(from: 0, to: -1, in: d))
        XCTAssertEqual(PDFTools.extract(pages: [-1, 4], from: d).pageCount, 0)
        XCTAssertNil(PDFTools.thumbnail(of: 3, in: d, size: CGSize(width: 50, height: 50)))
        XCTAssertEqual(texts(d), ["A", "B"])
    }

    func testThumbnailAndSave() throws {
        let src = try makePDF("s.pdf", pages: ["A", "B"])
        let d = try XCTUnwrap(PDFDocument(url: src))
        XCTAssertNotNil(PDFTools.thumbnail(of: 0, in: d, size: CGSize(width: 60, height: 40)))

        PDFTools.delete(pages: [0], in: d)
        let placed = try PDFTools.save(d, for: src, cacheDir: cache)
        XCTAssertFalse(placed.inCache)
        XCTAssertNil(placed.notice)
        let out = placed.url
        XCTAssertTrue(out.lastPathComponent.contains("bearbeitet"))
        XCTAssertEqual(texts(try XCTUnwrap(PDFDocument(url: out))), ["B"])
        XCTAssertEqual(PDFDocument(url: src)?.pageCount, 2)
        XCTAssertThrowsError(try PDFTools.save(PDFDocument(), for: src, cacheDir: cache))
    }

    func testMergeReplaceOriginalNeverReplacesInput() throws {
        let a = try makePDF("a.pdf", pages: ["A1"])
        let b = try makePDF("b.pdf", pages: ["B1"])
        let before = try Data(contentsOf: a)
        let r = try PDFTools.merge([a, b], mode: .replaceOriginal, cacheDir: cache)
        XCTAssertEqual(try Data(contentsOf: a), before, "Eingabe wurde ersetzt")
        XCTAssertNotEqual(r.url.standardizedFileURL, a.standardizedFileURL)
        XCTAssertTrue(r.url.lastPathComponent.contains("zusammengefügt"))
        XCTAssertFalse(r.placement.inCache)
        XCTAssertEqual(PDFDocument(url: r.url)?.pageCount, 2)
    }

    /// Interne Links einer angehängten PDF müssen auf die versetzte Seite zeigen (vorwärts und rückwärts).
    func testMergeKeepsInternalLinks() throws {
        let a = try makePDF("a.pdf", pages: ["A1", "A2"])
        let base = try openDoc(["B1", "B2", "B3"])
        let d = PDFDocument()
        for i in 0..<base.pageCount { d.insert(try XCTUnwrap(base.page(at: i)), at: d.pageCount) }
        func link(on page: Int, to target: Int, action: Bool) throws {
            let l = PDFAnnotation(bounds: CGRect(x: action ? 70 : 10, y: 10, width: 50, height: 20), forType: .link, withProperties: nil)
            let dest = PDFDestination(page: try XCTUnwrap(d.page(at: target)), at: .zero)
            if action { l.action = PDFActionGoTo(destination: dest) } else { l.destination = dest }
            try XCTUnwrap(d.page(at: page)).addAnnotation(l)
        }
        // Seite 0 → 1 (vorwärts), Seite 2 → 1 (rückwärts, Zielseite ist dann schon umgehängt).
        for action in [false, true] { try link(on: 0, to: 1, action: action); try link(on: 2, to: 1, action: action) }
        let b = tmp.appendingPathComponent("b.pdf")
        XCTAssertTrue(d.write(to: b))

        let out = try XCTUnwrap(PDFDocument(url: PDFTools.merge([a, b], cacheDir: cache).url))
        XCTAssertEqual(out.pageCount, 5)
        for page in [2, 4] {
            let targets = try XCTUnwrap(out.page(at: page)).annotations.filter { $0.type == "Link" }
                .map { ((($0.action as? PDFActionGoTo)?.destination ?? $0.destination)?.page).map(out.index(for:)) }
            XCTAssertEqual(targets, [3, 3], "Seite \(page): interner Link zeigt auf falsche Seite")
        }
    }

    /// Übersprungene Dateien bestimmen weder Name noch Ort: das tut die erste übernommene.
    func testMergeNamesAfterFirstUsableFile() throws {
        let other = tmp.appendingPathComponent("anderswo")
        try fm.createDirectory(at: other, withIntermediateDirectories: true)
        let broken = other.appendingPathComponent("0.pdf"); try Data("kein pdf".utf8).write(to: broken)
        let txt = other.appendingPathComponent("1.txt"); try Data("x".utf8).write(to: txt)
        let a = try makePDF("a.pdf", pages: ["A1"])
        let r = try PDFTools.merge([broken, txt, a], cacheDir: cache)
        XCTAssertEqual(r.url.lastPathComponent, "a (zusammengefügt).pdf")
        XCTAssertEqual(r.url.deletingLastPathComponent().standardizedFileURL, tmp.standardizedFileURL)
        XCTAssertEqual(r.skipped, [broken, txt])
    }

    func testNothingToMergeThrows() throws {
        let txt = tmp.appendingPathComponent("c.txt"); try Data("x".utf8).write(to: txt)
        XCTAssertThrowsError(try PDFTools.merge([txt], cacheDir: cache)) {
            XCTAssertEqual(($0 as? PDFToolsError)?.errorDescription, PDFToolsError.nothingToMerge.errorDescription)
        }
        XCTAssertThrowsError(try PDFTools.merge([], cacheDir: cache))
    }

    // MARK: 14.3 Komprimieren

    /// Eine Seite mit 2000×2000-Rauschbild (unkomprimierbar) plus echtem Text, zweite Seite gedreht mit Text.
    private func makeImagePDF(_ name: String) throws -> URL {
        let url = tmp.appendingPathComponent(name)
        let n = 2000
        var px = [UInt8](repeating: 0, count: n * n * 4)
        px.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) }
        let img = try px.withUnsafeMutableBytes { b in
            try XCTUnwrap(CGContext(data: b.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)?.makeImage())
        }
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let ctx = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        for text in ["Hallo Kompression", "Zweite Seite"] {
            ctx.beginPDFPage(nil)
            if text.hasPrefix("Hallo") { ctx.draw(img, in: CGRect(x: 56, y: 200, width: 500, height: 500)) }
            let attr = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 24)])
            ctx.textPosition = CGPoint(x: 56, y: 100)
            CTLineDraw(CTLineCreateWithAttributedString(attr), ctx)
            ctx.endPDFPage()
        }
        ctx.closePDF()
        // Zweite Seite drehen, damit „Stark“ die Drehung nachweislich übernimmt.
        let doc = try XCTUnwrap(PDFDocument(url: url))
        doc.page(at: 1)?.rotation = 90
        XCTAssertTrue(doc.write(to: url))
        return url
    }

    private func size(_ url: URL) throws -> Int64 {
        try XCTUnwrap(fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber).int64Value
    }

    func testCompressAllLevelsSmallerKeepsPagesAndText() throws {
        let src = try makeImagePDF("bild.pdf")
        let original = try size(src)
        for level in CompressionLevel.allCases {
            let r = try PDFTools.compress(src, level: level, mode: .cache, cacheDir: cache)
            print("PDF-Kompression \(level): \(r.originalSize) -> \(r.newSize) Bytes")
            XCTAssertEqual(r.originalSize, original)
            if level != .low { XCTAssertTrue(r.isSmaller, "\(level) nicht kleiner") }
            guard r.isSmaller else { XCTAssertEqual(r.url, src); continue }
            XCTAssertEqual(r.newSize, try size(r.url))
            XCTAssertTrue(r.url.lastPathComponent.contains("komprimiert"))
            XCTAssertEqual(r.url.pathExtension, "pdf")
            let doc = try XCTUnwrap(PDFDocument(url: r.url))
            XCTAssertEqual(doc.pageCount, 2, "\(level)")
            XCTAssertTrue(doc.string?.contains("Hallo Kompression") == true, "\(level): Text weg")
            XCTAssertTrue(doc.string?.contains("Zweite Seite") == true, "\(level): Text weg")
            // Gedrehte Seite behält ihre sichtbare Ausrichtung (Hochformat 612×792 → 792×612 gedreht).
            let p = try XCTUnwrap(doc.page(at: 1))
            let b = p.bounds(for: .cropBox)
            let visible = p.rotation % 180 == 0 ? b.size : CGSize(width: b.height, height: b.width)
            XCTAssertEqual(visible.width, 792, accuracy: 1, "\(level)")
            XCTAssertEqual(visible.height, 612, accuracy: 1, "\(level)")
        }
        XCTAssertEqual(try size(src), original, "Original darf nicht verändert werden")
    }

    /// Nicht kleiner: nichts ablegen, nie das Original ersetzen, Ergebnis zeigt auf die Quelle.
    func testCompressNotSmallerPlacesNothing() throws {
        let src = try makePDF("text.pdf", pages: ["Nur Text"])
        let bytes = try Data(contentsOf: src)
        // Nur-Text-PDF: low/medium werden durch PDFKits Neuschreiben sicher etwas größer.
        for level in [CompressionLevel.low, .medium] {
            for mode in [OutputMode.besideOriginal, .cache, .replaceOriginal] {
                let r = try PDFTools.compress(src, level: level, mode: mode, cacheDir: cache)
                print("PDF-Kompression nur Text (\(level), \(mode)): \(r.originalSize) -> \(r.newSize) Bytes")
                XCTAssertFalse(r.isSmaller, "\(level): Testdatei sollte nicht kleiner werden")
                XCTAssertEqual(r.url, src)
                XCTAssertNil(r.placement)
                XCTAssertEqual(try Data(contentsOf: src), bytes, "Original verändert (\(level), \(mode))")
                XCTAssertEqual(try fm.contentsOfDirectory(atPath: tmp.path), ["text.pdf"], "\(level), \(mode)")
            }
        }
        XCTAssertEqual((try? fm.contentsOfDirectory(atPath: cache.path)) ?? [], [], "Cache muss leer bleiben")
    }

    /// Ordner ohne Schreibrecht: Ergebnis landet im Cache, und der Hinweis kommt beim Aufrufer an.
    func testCacheFallbackNoticeReachesCaller() throws {
        let ro = tmp.appendingPathComponent("schreibgeschützt")
        try fm.createDirectory(at: ro, withIntermediateDirectories: true)
        let pdf = try makeImagePDF("schreibgeschützt/bild.pdf")
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: ro.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ro.path) }

        let m = try PDFTools.merge([pdf], cacheDir: cache)
        let c = try PDFTools.compress(pdf, level: .high, cacheDir: cache)
        let s = try PDFTools.save(try XCTUnwrap(PDFDocument(url: pdf)), for: pdf, cacheDir: cache)
        for p in [m.placement, try XCTUnwrap(c.placement), s] {
            XCTAssertTrue(p.inCache)
            XCTAssertNotNil(p.notice)
            XCTAssertEqual(p.url.deletingLastPathComponent().standardizedFileURL, cache.standardizedFileURL)
        }
        XCTAssertEqual(c.url, c.placement?.url)
    }

    /// Low/Medium bauen ein neues Dokument: Metadaten, Lesezeichen und interne Links müssen mit.
    func testCompressKeepsMetadataOutlineAndLinks() throws {
        let base = try XCTUnwrap(PDFDocument(url: makeImagePDF("basis.pdf")))
        // Frisches Dokument, sonst schreibt PDFKit Outline/Metadaten nicht mit.
        let d = PDFDocument()
        for i in 0..<base.pageCount { d.insert(try XCTUnwrap(base.page(at: i)), at: d.pageCount) }
        d.documentAttributes = [PDFDocumentAttribute.titleAttribute: "Titel X", PDFDocumentAttribute.authorAttribute: "Autor Y"]
        let root = PDFOutline(); d.outlineRoot = root
        let o = PDFOutline(); o.label = "Kapitel 2"
        o.destination = PDFDestination(page: try XCTUnwrap(d.page(at: 1)), at: .zero)
        root.insertChild(o, at: 0)
        let p0 = try XCTUnwrap(d.page(at: 0))
        let dest = PDFAnnotation(bounds: CGRect(x: 10, y: 10, width: 50, height: 20), forType: .link, withProperties: nil)
        dest.destination = PDFDestination(page: try XCTUnwrap(d.page(at: 1)), at: .zero)
        let act = PDFAnnotation(bounds: CGRect(x: 70, y: 10, width: 50, height: 20), forType: .link, withProperties: nil)
        act.action = PDFActionGoTo(destination: PDFDestination(page: try XCTUnwrap(d.page(at: 1)), at: .zero))
        let web = PDFAnnotation(bounds: CGRect(x: 130, y: 10, width: 50, height: 20), forType: .link, withProperties: nil)
        web.url = URL(string: "https://example.com")
        let field = PDFAnnotation(bounds: CGRect(x: 10, y: 40, width: 100, height: 20), forType: .widget, withProperties: nil)
        field.widgetFieldType = .text; field.fieldName = "Feld1"; field.widgetStringValue = "Wert"
        let note = PDFAnnotation(bounds: CGRect(x: 10, y: 70, width: 20, height: 20), forType: .text, withProperties: nil)
        note.contents = "Notiz"
        [dest, act, web, field, note].forEach(p0.addAnnotation)
        let src = tmp.appendingPathComponent("reich.pdf")
        XCTAssertTrue(d.write(to: src))

        for level in [CompressionLevel.low, .medium] {
            let r = try PDFTools.compress(src, level: level, mode: .cache, cacheDir: cache)
            XCTAssertTrue(r.isSmaller, "\(level)")
            let out = try XCTUnwrap(PDFDocument(url: r.url))
            let attrs = out.documentAttributes ?? [:]
            XCTAssertEqual(attrs[PDFDocumentAttribute.titleAttribute] as? String, "Titel X", "\(level)")
            XCTAssertEqual(attrs[PDFDocumentAttribute.authorAttribute] as? String, "Autor Y", "\(level)")
            let item = try XCTUnwrap(out.outlineRoot?.child(at: 0), "\(level): Lesezeichen weg")
            XCTAssertEqual(item.label, "Kapitel 2")
            XCTAssertEqual(item.destination?.page.map(out.index(for:)), 1, "\(level)")
            let anns = try XCTUnwrap(out.page(at: 0)).annotations
            func target(_ a: PDFAnnotation) -> Int? {
                ((a.action as? PDFActionGoTo)?.destination ?? a.destination)?.page.map(out.index(for:))
            }
            let goTo = anns.filter { $0.type == "Link" && $0.url == nil }
            XCTAssertEqual(goTo.count, 2, "\(level)")
            XCTAssertEqual(goTo.map(target), [1, 1], "\(level): interner Link zeigt auf falsche Seite")
            XCTAssertTrue(anns.contains { $0.url == URL(string: "https://example.com") }, "\(level)")
            XCTAssertTrue(anns.contains { $0.fieldName == "Feld1" && $0.widgetStringValue == "Wert" }, "\(level)")
            XCTAssertTrue(anns.contains { $0.type == "Text" && $0.contents == "Notiz" }, "\(level)")
        }
    }

    func testCompressUnreadableThrows() throws {
        let bad = tmp.appendingPathComponent("kaputt.pdf"); try Data("kein pdf".utf8).write(to: bad)
        XCTAssertThrowsError(try PDFTools.compress(bad, level: .low, cacheDir: cache)) {
            XCTAssertEqual(($0 as? PDFToolsError)?.errorDescription, PDFToolsError.unreadable.errorDescription)
        }
    }

    func testCompressionWarningOnlyForHigh() {
        XCTAssertNil(CompressionLevel.low.warning)
        XCTAssertNil(CompressionLevel.medium.warning)
        XCTAssertNotNil(CompressionLevel.high.warning)
    }
}
