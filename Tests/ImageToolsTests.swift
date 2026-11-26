import XCTest
import ImageIO
import UniformTypeIdentifiers
import Vision

/// Hostless: nur eigener Temp-Ordner; `cacheDir` zeigt nie auf den echten Cache.
final class ImageToolsTests: XCTestCase {
    private var tmp: URL!
    private var cache: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        tmp = fm.temporaryDirectory.appendingPathComponent("dropshelf-imagetools-" + UUID().uuidString)
        cache = tmp.appendingPathComponent("cache")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? fm.removeItem(at: tmp) }

    /// 3×2: obere Reihe rot, grün, blau; untere Reihe gelb, weiß, schwarz (opak).
    private let pixels: [[UInt8]] = [[255, 0, 0], [0, 255, 0], [0, 0, 255], [255, 255, 0], [255, 255, 255], [0, 0, 0]]

    private func makeImage(_ name: String, type: UTType) throws -> URL {
        var data = [UInt8]()
        for p in pixels { data += p + [255] }
        let cg = CGContext(data: &data, width: 3, height: 2, bitsPerComponent: 8, bytesPerRow: 12,
                           space: CGColorSpaceCreateDeviceRGB(),
                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        let url = tmp.appendingPathComponent(name)
        let d = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(d, cg, nil)
        XCTAssertTrue(CGImageDestinationFinalize(d))
        return url
    }

    /// Liest Größe und RGB-Werte (Zeile für Zeile, oben links beginnend).
    private func read(_ url: URL) throws -> (w: Int, h: Int, px: [[UInt8]]) {
        let src = CGImageSourceCreateWithURL(url as CFURL, nil)!
        let img = CGImageSourceCreateImageAtIndex(src, 0, nil)!
        let w = img.width, h = img.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return (w, h, (0..<w*h).map { [data[$0*4], data[$0*4+1], data[$0*4+2]] })
    }

    func testOrientationMath() {
        XCTAssertEqual(ImageTools.orientation(1, after: .cw), 6)
        XCTAssertEqual(ImageTools.orientation(1, after: .ccw), 8)
        XCTAssertEqual(ImageTools.orientation(6, after: .cw), 3)
        XCTAssertEqual(ImageTools.orientation(1, after: .flipH), 2)
        XCTAssertEqual(ImageTools.orientation(1, after: .flipV), 4)
        XCTAssertEqual(ImageTools.orientation(2, after: .flipH), 1)
        for o in UInt32(1)...8 {
            XCTAssertEqual(ImageTools.orientation(ImageTools.orientation(o, after: .cw), after: .ccw), o)
        }
    }

    func testRotatePNGClockwise() throws {
        let src = try makeImage("a.png", type: .png)
        let out = try ImageTools.rotate(src, clockwise: true, cacheDir: cache)
        let r = try read(out)
        XCTAssertEqual(r.w, 2); XCTAssertEqual(r.h, 3)
        // Im Uhrzeigersinn: linke Spalte = untere Reihe von links nach rechts, von oben nach unten.
        XCTAssertEqual(r.px, [pixels[3], pixels[0], pixels[4], pixels[1], pixels[5], pixels[2]])
    }

    func testRotatePNGCounterclockwise() throws {
        let src = try makeImage("a.png", type: .png)
        let r = try read(try ImageTools.rotate(src, clockwise: false, cacheDir: cache))
        XCTAssertEqual(r.px, [pixels[2], pixels[5], pixels[1], pixels[4], pixels[0], pixels[3]])
    }

    func testFlipPNG() throws {
        let src = try makeImage("a.png", type: .png)
        let h = try read(try ImageTools.flip(src, horizontal: true, cacheDir: cache))
        XCTAssertEqual(h.px, [pixels[2], pixels[1], pixels[0], pixels[5], pixels[4], pixels[3]])
        let v = try read(try ImageTools.flip(src, horizontal: false, cacheDir: cache))
        XCTAssertEqual(v.px, [pixels[3], pixels[4], pixels[5], pixels[0], pixels[1], pixels[2]])
    }

    func testJPEGRotateSetsOrientationAndKeepsOriginal() throws {
        let src = try makeImage("a.jpg", type: .jpeg)
        let before = try Data(contentsOf: src)
        let out = try ImageTools.rotate(src, clockwise: true, cacheDir: cache)
        XCTAssertNotEqual(out, src)
        XCTAssertEqual(try Data(contentsOf: src), before)
        let s = CGImageSourceCreateWithURL(out as CFURL, nil)!
        let props = CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as! [CFString: Any]
        XCTAssertEqual(props[kCGImagePropertyOrientation] as? UInt32, 6)
        // Zweite Drehung addiert sich auf 180°.
        let out2 = try ImageTools.rotate(out, clockwise: true, cacheDir: cache)
        let p2 = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithURL(out2 as CFURL, nil)!, 0, nil) as! [CFString: Any]
        XCTAssertEqual(p2[kCGImagePropertyOrientation] as? UInt32, 3)
    }

    func testReplaceOriginal() throws {
        let src = try makeImage("a.png", type: .png)
        let out = try ImageTools.rotate(src, clockwise: true, mode: .replaceOriginal, cacheDir: cache)
        XCTAssertEqual(out.lastPathComponent, "a.png")
        XCTAssertEqual(try read(out).w, 2)
    }

    func testUnreadableThrows() throws {
        let bad = tmp.appendingPathComponent("x.png")
        try Data("nope".utf8).write(to: bad)
        XCTAssertThrowsError(try ImageTools.rotate(bad, clockwise: true, cacheDir: cache))
    }

    // MARK: 13.2 Zuschneiden

    private func assertRect(_ a: CGRect, _ b: CGRect, line: UInt = #line) {
        XCTAssertEqual(a.minX, b.minX, accuracy: 1e-9, line: line); XCTAssertEqual(a.minY, b.minY, accuracy: 1e-9, line: line)
        XCTAssertEqual(a.width, b.width, accuracy: 1e-9, line: line); XCTAssertEqual(a.height, b.height, accuracy: 1e-9, line: line)
    }

    func testFitAspect() {
        let sz = CGSize(width: 1000, height: 1000)
        // free: unverändert, aber an den Rand geklemmt
        assertRect(ImageTools.fitAspect(CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.3), in: sz, .free), CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.3))
        assertRect(ImageTools.fitAspect(CGRect(x: 0.8, y: 0.8, width: 0.5, height: 0.5), in: sz, .free), CGRect(x: 0.8, y: 0.8, width: 0.2, height: 0.2))
        // quadratisch: breit -> Breite schrumpft um die Mitte
        assertRect(ImageTools.fitAspect(CGRect(x: 0, y: 0.25, width: 1, height: 0.5), in: sz, .square), CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
        // 16:9 auf ganzem Bild: Höhe schrumpft, bleibt am Rand im Bild
        assertRect(ImageTools.fitAspect(CGRect(x: 0, y: 0, width: 1, height: 1), in: sz, .r16x9), CGRect(x: 0, y: 0.21875, width: 1, height: 0.5625))
        // 4:3 bei Querformat-Bild: Pixelverhältnis zählt, nicht das normalisierte
        assertRect(ImageTools.fitAspect(CGRect(x: 0, y: 0, width: 1, height: 1), in: CGSize(width: 400, height: 300), .r4x3), CGRect(x: 0, y: 0, width: 1, height: 1))
        // sehr schmal: Höhe schrumpft auf Mindestbreite-Verhältnis
        let n = ImageTools.fitAspect(CGRect(x: 0.5, y: 0, width: 0.01, height: 1), in: sz, .square)
        assertRect(n, CGRect(x: 0.5, y: 0.495, width: 0.01, height: 0.01))
        // leer / außerhalb
        XCTAssertEqual(ImageTools.fitAspect(CGRect(x: 2, y: 2, width: 1, height: 1), in: sz, .square), .zero)
        XCTAssertEqual(ImageTools.fitAspect(CGRect(x: 0, y: 0, width: 1, height: 1), in: .zero, .square), .zero)
    }

    func testCropPixelSizeAndContent() throws {
        let src = try makeImage("a.png", type: .png)
        // rechte zwei Spalten, untere Reihe
        let out = try ImageTools.crop(src, to: CGRect(x: 1.0/3, y: 0.5, width: 2.0/3, height: 0.5), cacheDir: cache)
        let r = try read(out)
        XCTAssertEqual(r.w, 2); XCTAssertEqual(r.h, 1)
        XCTAssertEqual(r.px, [pixels[4], pixels[5]])
        XCTAssertTrue(fm.fileExists(atPath: src.path))
    }

    func testCropJPEGAndEmptyThrows() throws {
        let src = try makeImage("a.jpg", type: .jpeg)
        let out = try ImageTools.crop(src, to: CGRect(x: 0, y: 0, width: 2.0/3, height: 1), cacheDir: cache)
        let r = try read(out)
        XCTAssertEqual(r.w, 2); XCTAssertEqual(r.h, 2)
        XCTAssertEqual(CGImageSourceGetType(CGImageSourceCreateWithURL(out as CFURL, nil)!) as String?, UTType.jpeg.identifier)
        XCTAssertThrowsError(try ImageTools.crop(src, to: CGRect(x: 0.5, y: 0.5, width: 0, height: 0.5), cacheDir: cache))
        XCTAssertThrowsError(try ImageTools.crop(src, to: CGRect(x: 2, y: 2, width: 1, height: 1), cacheDir: cache))
    }

    func testPreviewAppURLIsNilOrApp() {
        if let u = ImageTools.previewAppURL() { XCTAssertEqual(u.pathExtension, "app") }
        XCTAssertNotNil(ImageToolsError.previewNotFound.errorDescription)
    }

    // MARK: 13.4 Hintergrund entfernen

    /// Kein Absturz; Ergebnis ist ein PNG mit Alpha oder ein sauberer Fehler
    /// (.noSubject, andere ImageToolsError oder Vision-Fehler, z. B. ohne GPU/ANE).
    func testRemoveBackgroundPNGWithAlphaOrCleanError() async throws {
        let w = 200, h = 200
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(red: 0.8, green: 0.1, blue: 0.1, alpha: 1)); ctx.fillEllipse(in: CGRect(x: 50, y: 50, width: 100, height: 100))
        let src = tmp.appendingPathComponent("bg.png")
        let d = CGImageDestinationCreateWithURL(src as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(d, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(d))

        do {
            let out = try await ImageTools.removeBackground(src, cacheDir: cache)
            XCTAssertEqual(out.pathExtension, "png")
            XCTAssertTrue(out.lastPathComponent.contains("ohne Hintergrund"))
            let s = CGImageSourceCreateWithURL(out as CFURL, nil)!
            XCTAssertEqual(CGImageSourceGetType(s) as String?, UTType.png.identifier)
            let a = CGImageSourceCreateImageAtIndex(s, 0, nil)!.alphaInfo
            XCTAssertFalse([.none, .noneSkipFirst, .noneSkipLast].contains(a))
        } catch let e as ImageToolsError {
            // erlaubt: .noSubject; andere ImageToolsError nur als sauberer Fehler mit Text
            XCTAssertNotNil(e.errorDescription)
        } catch {
            // Vision-Fehler in der Testumgebung (z. B. keine GPU/ANE) ist ein sauberer Fehler.
            XCTAssertEqual((error as NSError).domain, VNErrorDomain, "\(error)")
        }
        XCTAssertTrue(fm.fileExists(atPath: src.path))
    }

    func testRemoveBackgroundUnreadableThrows() async throws {
        let bad = tmp.appendingPathComponent("x.png")
        try Data("nope".utf8).write(to: bad)
        do { _ = try await ImageTools.removeBackground(bad, cacheDir: cache); XCTFail("sollte werfen") }
        catch ImageToolsError.unreadable {}
        XCTAssertEqual(ImageToolsError.noSubject.errorDescription, "Kein Motiv erkannt")
    }
}
