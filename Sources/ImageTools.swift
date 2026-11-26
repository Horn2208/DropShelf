import Foundation
import AppKit
import ImageIO
import CoreImage
import Vision
import UniformTypeIdentifiers

enum ImageToolsError: LocalizedError {
    case unreadable, writeFailed, emptyCrop, previewNotFound, noSubject

    var errorDescription: String? {
        switch self {
        case .unreadable: return "Das Bild konnte nicht gelesen werden."
        case .writeFailed: return "Das Bild konnte nicht geschrieben werden."
        case .emptyCrop: return "Der Zuschnitt ist leer."
        case .previewNotFound: return "Die Vorschau-App wurde nicht gefunden."
        case .noSubject: return "Kein Motiv erkannt"
        }
    }
}

enum CropAspect { case free, square, r16x9, r4x3 }

/// Skalierung für Bildausgaben.
enum ImageScale: Sendable { case percent(Int), maxEdge(Int), original }

/// Zielgröße in ganzen Pixeln, Seitenverhältnis bleibt, nie größer als `s`. Reine Funktion.
func targetSize(_ s: CGSize, _ k: ImageScale) -> CGSize {
    let f: CGFloat
    switch k {
    case .original: return s
    case .percent(let p): f = min(1, CGFloat(max(p, 1)) / 100)
    case .maxEdge(let e):
        let m = max(s.width, s.height)
        f = m > 0 ? min(1, CGFloat(max(e, 1)) / m) : 1
    }
    return CGSize(width: max(1, (s.width * f).rounded()), height: max(1, (s.height * f).rounded()))
}

/// Reine Bildfunktionen auf URLs (kein UI). Ergebnisse gehen über `FileOutput`.
enum ImageTools {
    // MARK: 13.1 Drehen/Spiegeln

    @discardableResult
    static func rotate(_ url: URL, clockwise: Bool, mode: OutputMode = .besideOriginal,
                       cacheDir: URL = Shelf.cacheDir) throws -> URL {
        try reorient(url, op: clockwise ? .cw : .ccw, suffix: "gedreht", mode: mode, cacheDir: cacheDir)
    }

    /// `horizontal`: links/rechts vertauschen, sonst oben/unten.
    @discardableResult
    static func flip(_ url: URL, horizontal: Bool, mode: OutputMode = .besideOriginal,
                     cacheDir: URL = Shelf.cacheDir) throws -> URL {
        try reorient(url, op: horizontal ? .flipH : .flipV, suffix: "gespiegelt", mode: mode, cacheDir: cacheDir)
    }

    enum Op { case cw, ccw, flipH, flipV }

    /// EXIF-Orientierung (1–8) als 2×2-Matrix (a b; c d), Bildschirm = M · gespeichert, y nach unten.
    private static let matrices: [UInt32: [Int]] = [
        1: [1, 0, 0, 1], 2: [-1, 0, 0, 1], 3: [-1, 0, 0, -1], 4: [1, 0, 0, -1],
        5: [0, 1, 1, 0], 6: [0, -1, 1, 0], 7: [0, -1, -1, 0], 8: [0, 1, -1, 0],
    ]

    /// Neue Orientierung nach `op`, angewendet auf die sichtbare Darstellung. Reine Funktion.
    static func orientation(_ current: UInt32, after op: Op) -> UInt32 {
        let m = matrices[current] ?? matrices[1]!
        let o: [Int]
        switch op {
        case .cw: o = [0, -1, 1, 0]
        case .ccw: o = [0, 1, -1, 0]
        case .flipH: o = [-1, 0, 0, 1]
        case .flipV: o = [1, 0, 0, -1]
        }
        let r = [o[0]*m[0] + o[1]*m[2], o[0]*m[1] + o[1]*m[3],
                 o[2]*m[0] + o[3]*m[2], o[2]*m[1] + o[3]*m[3]]
        return matrices.first { $0.value == r }!.key
    }

    private static func reorient(_ url: URL, op: Op, suffix: String, mode: OutputMode, cacheDir: URL) throws -> URL {
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }

        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let type = CGImageSourceGetType(src),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        else { throw ImageToolsError.unreadable }
        let current = (props[kCGImagePropertyOrientation] as? UInt32) ?? 1
        let new = orientation(current, after: op)

        let ext = url.pathExtension
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + (ext.isEmpty ? "" : "." + ext))
        do {
            // JPEG/HEIC: nur das Tag ändern (verlustfrei); sonst oder bei Fehlschlag neu zeichnen.
            let lossy = UTType(type as String).map { $0.conforms(to: .jpeg) || $0.conforms(to: .heic) } ?? false
            if !(lossy && (try? copyWithOrientation(src, type: type, to: tmp, new)) == true) {
                try redraw(src, type: type, to: tmp, new)
            }
            return try FileOutput.place(tmp, for: url, suffix: suffix, ext: ext, mode: mode, cacheDir: cacheDir)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
    }

    private static func copyWithOrientation(_ src: CGImageSource, type: CFString, to tmp: URL, _ o: UInt32) throws -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(tmp as CFURL, type, 1, nil) else { return false }
        var err: Unmanaged<CFError>?
        let opts = [kCGImageDestinationOrientation: o] as CFDictionary
        return CGImageDestinationCopyImageSource(dest, src, opts, &err)
    }

    /// Zeichnet die Pixel mit der Orientierung neu und schreibt sie ohne Tag (Metadaten gehen dabei verloren).
    private static func redraw(_ src: CGImageSource, type: CFString, to tmp: URL, _ o: UInt32) throws {
        guard let raw = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw ImageToolsError.unreadable }
        let ci = CIImage(cgImage: raw).oriented(CGImagePropertyOrientation(rawValue: o) ?? .up)
        guard let out = CIContext().createCGImage(ci, from: ci.extent),
              let dest = CGImageDestinationCreateWithURL(tmp as CFURL, type, 1, nil)
        else { throw ImageToolsError.writeFailed }
        CGImageDestinationAddImage(dest, out, nil)
        guard CGImageDestinationFinalize(dest) else { throw ImageToolsError.writeFailed }
    }

    // MARK: 13.2 Zuschneiden

    /// Passt ein normalisiertes Rechteck (0...1, Ursprung oben links) um seine Mitte an das Seitenverhältnis an
    /// (nur verkleinern) und begrenzt es auf das Bild. `size` ist die Pixelgröße des Bildes. Reine Funktion.
    static func fitAspect(_ rect: CGRect, in size: CGSize, _ a: CropAspect) -> CGRect {
        let r = rect.standardized.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        let ratio: CGFloat
        switch a {
        case .free: return r.isNull ? .zero : r
        case .square: ratio = 1
        case .r16x9: ratio = 16.0 / 9
        case .r4x3: ratio = 4.0 / 3
        }
        guard !r.isNull, r.width > 0, r.height > 0, size.width > 0, size.height > 0 else { return .zero }
        var w = r.width, h = r.height
        if w * size.width / (h * size.height) > ratio { w = h * size.height * ratio / size.width }
        else { h = w * size.width / (ratio * size.height) }
        return CGRect(x: r.midX - w / 2, y: r.midY - h / 2, width: w, height: h)
    }

    /// Schneidet auf das normalisierte Rechteck (Ursprung oben links) zu. Sichtbare Orientierung wird berücksichtigt.
    /// JPEG wird mit Qualität 0,95 neu kodiert.
    @discardableResult
    static func crop(_ url: URL, to normalized: CGRect, mode: OutputMode = .besideOriginal,
                     cacheDir: URL = Shelf.cacheDir) throws -> URL {
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }

        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let type = CGImageSourceGetType(src),
              var img = CGImageSourceCreateImageAtIndex(src, 0, nil)
        else { throw ImageToolsError.unreadable }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        if let o = props?[kCGImagePropertyOrientation] as? UInt32, o != 1,
           let up = CGImagePropertyOrientation(rawValue: o) {
            let ci = CIImage(cgImage: img).oriented(up)
            guard let fixed = CIContext().createCGImage(ci, from: ci.extent) else { throw ImageToolsError.unreadable }
            img = fixed
        }
        let n = normalized.standardized.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        let w = CGFloat(img.width), h = CGFloat(img.height)
        let px = CGRect(x: (n.minX * w).rounded(), y: (n.minY * h).rounded(),
                        width: (n.width * w).rounded(), height: (n.height * h).rounded())
        guard !n.isNull, px.width >= 1, px.height >= 1, let out = img.cropping(to: px) else { throw ImageToolsError.emptyCrop }

        let ext = url.pathExtension
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + (ext.isEmpty ? "" : "." + ext))
        do {
            guard let dest = CGImageDestinationCreateWithURL(tmp as CFURL, type, 1, nil) else { throw ImageToolsError.writeFailed }
            let opts = [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary
            CGImageDestinationAddImage(dest, out, opts)
            guard CGImageDestinationFinalize(dest) else { throw ImageToolsError.writeFailed }
            return try FileOutput.place(tmp, for: url, suffix: "zugeschnitten", ext: ext, mode: mode, cacheDir: cacheDir)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
    }

    // MARK: 13.3 Annotieren (in Vorschau.app)

    /// Ort der Vorschau.app oder nil. Öffnet nichts.
    static func previewAppURL() -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview")
    }

    /// Öffnet das Original in Vorschau.app (Markup dort). Fehler beim Öffnen selbst werden nicht gemeldet.
    @MainActor
    static func openInPreview(_ url: URL) throws {
        guard let app = previewAppURL() else { throw ImageToolsError.previewNotFound }
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: 13.4 Hintergrund entfernen

    /// Stellt das Motiv frei (Vision) und schreibt ein PNG mit Alphakanal. Ohne Vordergrund: `.noSubject`.
    @discardableResult
    static func removeBackground(_ url: URL, mode: OutputMode = .besideOriginal,
                                 cacheDir: URL = Shelf.cacheDir) async throws -> URL {
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }

        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let raw = CGImageSourceCreateImageAtIndex(src, 0, nil)
        else { throw ImageToolsError.unreadable }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let o = CGImagePropertyOrientation(rawValue: (props?[kCGImagePropertyOrientation] as? UInt32) ?? 1) ?? .up

        let png = try await Task.detached { () throws -> Data in
            let request = VNGenerateForegroundInstanceMaskRequest()
            let handler = VNImageRequestHandler(cgImage: raw, orientation: o)
            try handler.perform([request])
            guard let obs = request.results?.first, !obs.allInstances.isEmpty else { throw ImageToolsError.noSubject }
            let buf = try obs.generateMaskedImage(ofInstances: obs.allInstances, from: handler, croppedToInstancesExtent: false)
            let ci = CIImage(cvPixelBuffer: buf)
            guard let data = CIContext().pngRepresentation(of: ci, format: .RGBA8,
                                                           colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            else { throw ImageToolsError.writeFailed }
            return data
        }.value

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        do {
            try png.write(to: tmp)
            return try FileOutput.place(tmp, for: url, suffix: "ohne Hintergrund", ext: "png", mode: mode, cacheDir: cacheDir)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
    }
}
