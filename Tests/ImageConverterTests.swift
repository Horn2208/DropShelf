import XCTest
import ImageIO
import PDFKit
import UniformTypeIdentifiers

final class ImageConverterTests: XCTestCase {
    private var tmp: URL!
    private var cache: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        tmp = fm.temporaryDirectory.appendingPathComponent("dropshelf-imgconv-" + UUID().uuidString)
        cache = tmp.appendingPathComponent("cache")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? fm.removeItem(at: tmp) }

    private func png(_ name: String = "Bild.png", w: Int = 200, h: Int = 100) throws -> URL {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let u = tmp.appendingPathComponent(name)
        let d = CGImageDestinationCreateWithURL(u as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(d, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(d))
        return u
    }

    private func type(_ u: URL) -> String? { CGImageSourceCreateWithURL(u as CFURL, nil).flatMap(CGImageSourceGetType) as String? }

    func testTargetSize() {
        let s = CGSize(width: 4000, height: 3000)
        XCTAssertEqual(targetSize(s, .percent(25)), CGSize(width: 1000, height: 750))
        XCTAssertEqual(targetSize(s, .percent(50)), CGSize(width: 2000, height: 1500))
        XCTAssertEqual(targetSize(s, .percent(75)), CGSize(width: 3000, height: 2250))
        XCTAssertEqual(targetSize(s, .maxEdge(1920)), CGSize(width: 1920, height: 1440))
        XCTAssertEqual(targetSize(s, .maxEdge(1080)), CGSize(width: 1080, height: 810))
        XCTAssertEqual(targetSize(CGSize(width: 3000, height: 4000), .maxEdge(1080)), CGSize(width: 810, height: 1080))
        XCTAssertEqual(targetSize(CGSize(width: 800, height: 600), .maxEdge(1920)), CGSize(width: 800, height: 600))
        XCTAssertEqual(targetSize(CGSize(width: 800, height: 600), .percent(150)), CGSize(width: 800, height: 600))
        XCTAssertEqual(targetSize(s, .original), s)
    }

    func testPNGToJPGWithScale() async throws {
        var o = ConvertOptions(); o.quality = 0.8; o.imageScale = .percent(50)
        let out = try await ConverterRegistry.convert(try png(), to: .jpeg, o, mode: .besideOriginal, cacheDir: cache)
        XCTAssertEqual(type(out), UTType.jpeg.identifier)
        let p = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithURL(out as CFURL, nil)!, 0, nil) as? [CFString: Any]
        XCTAssertEqual(p?[kCGImagePropertyPixelWidth] as? Int, 100)
    }

    func testPNGToHEICOrCleanError() async throws {
        do {
            let out = try await ConverterRegistry.convert(try png(), to: .heic, mode: .besideOriginal, cacheDir: cache)
            XCTAssertEqual(type(out), UTType.heic.identifier)
        } catch ConvertError.heicUnavailable {
            // kein HEVC-Encoder: sauberer Fehler ist erlaubt
        }
    }

    func testTargets() {
        let p = ConverterRegistry.targets(for: .png)
        XCTAssertTrue(p.contains(.jpeg)); XCTAssertTrue(p.contains(.heic) || !ImageConverter.writable.contains(.heic))
        XCTAssertTrue(p.contains(.webP))
        let w = ConverterRegistry.targets(for: .webP)
        XCTAssertTrue(w.contains(.png)); XCTAssertTrue(w.contains(.jpeg)); XCTAssertFalse(w.contains(.webP))
    }

    func testPNGToWebPRoundTrip() async throws {
        let src = try png("Quadrat.png", w: 64, h: 64)
        var o = ConvertOptions(); o.quality = 0.85
        let webp = try await ConverterRegistry.convert(src, to: .webP, o, mode: .cache, cacheDir: cache)
        XCTAssertEqual(webp.pathExtension, "webp")
        let bytes = try Data(contentsOf: webp)
        XCTAssertEqual(bytes.prefix(4), Data("RIFF".utf8))
        XCTAssertEqual(bytes[8..<12], Data("WEBP".utf8))
        XCTAssertEqual(type(webp), UTType.webP.identifier)
        let back = try await ConverterRegistry.convert(webp, to: .png, mode: .cache, cacheDir: cache)
        XCTAssertEqual(type(back), UTType.png.identifier)
        let p = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithURL(back as CFURL, nil)!, 0, nil) as? [CFString: Any]
        XCTAssertEqual(p?[kCGImagePropertyPixelWidth] as? Int, 64)
        XCTAssertEqual(p?[kCGImagePropertyPixelHeight] as? Int, 64)
    }

    func testPNGToBMP() async throws {
        try XCTSkipUnless(ImageConverter.writable.contains(.bmp), "BMP-Ausgang auf diesem Mac nicht verfügbar")
        let out = try await ConverterRegistry.convert(try png("Test.png", w: 40, h: 30), to: .bmp, mode: .cache, cacheDir: cache)
        XCTAssertEqual(out.pathExtension, "bmp")
        XCTAssertEqual(type(out), UTType.bmp.identifier)
    }

    func testPNGToPDF() async throws {
        XCTAssertTrue(ConverterRegistry.targets(for: .png).contains(.pdf))
        let out = try await ConverterRegistry.convert(try png("Seite.png", w: 120, h: 80), to: .pdf, mode: .cache, cacheDir: cache)
        XCTAssertEqual(out.pathExtension, "pdf")
        let doc = try XCTUnwrap(PDFDocument(url: out))
        XCTAssertEqual(doc.pageCount, 1)
        let bounds = doc.page(at: 0)?.bounds(for: .mediaBox) ?? .zero
        XCTAssertGreaterThan(bounds.width, 0)
        XCTAssertGreaterThan(bounds.height, 0)
    }

    func testPNGToAVIF() async throws {
        try XCTSkipUnless(ImageConverter.writable.contains(ImageConverter.avif), "AVIF-Ausgang auf diesem Mac nicht verfügbar")
        let out = try await ConverterRegistry.convert(try png("Avif.png", w: 64, h: 64), to: ImageConverter.avif, mode: .cache, cacheDir: cache)
        XCTAssertEqual(out.pathExtension, "avif")
        XCTAssertEqual(type(out), ImageConverter.avif.identifier)
    }

    func testPNGWithAlphaFlattensToWhiteInJPEG() async throws {
        let w = 32, h = 32
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 12, y: 12, width: 8, height: 8))
        let srcURL = tmp.appendingPathComponent("Alpha.png")
        let dest = CGImageDestinationCreateWithURL(srcURL as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))

        var o = ConvertOptions(); o.quality = 1.0
        let jpg = try await ConverterRegistry.convert(srcURL, to: .jpeg, o, mode: .cache, cacheDir: cache)
        XCTAssertEqual(type(jpg), UTType.jpeg.identifier)

        let src = try XCTUnwrap(CGImageSourceCreateWithURL(jpg as CFURL, nil))
        let cg = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
        var px = [UInt8](repeating: 0, count: 4)
        let readCtx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        readCtx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        // Ecke (0,0) war voll transparent → muss auf Weiß geflattet sein (nicht Schwarz)
        XCTAssertGreaterThan(px[0], 240, "R sollte weiß sein: \(px)")
        XCTAssertGreaterThan(px[1], 240, "G sollte weiß sein: \(px)")
        XCTAssertGreaterThan(px[2], 240, "B sollte weiß sein: \(px)")
    }

    func testRAWTargetsAndUnreadableHandling() async throws {
        XCTAssertTrue(ConverterRegistry.targets(for: .rawImage).contains(.jpeg))
        XCTAssertTrue(ConverterRegistry.targets(for: .rawImage).contains(.png))
        let bogus = tmp.appendingPathComponent("defekt.dng")
        try Data("not a raw image".utf8).write(to: bogus)
        do {
            _ = try await ConverterRegistry.convert(bogus, to: .jpeg, mode: .cache, cacheDir: cache)
            XCTFail("Ungültiges RAW sollte fehlschlagen")
        } catch ConvertError.unreadable {
            // erwartet
        }
    }
}
