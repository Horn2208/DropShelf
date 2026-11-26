import Foundation
import AppKit
import ImageIO
import CoreGraphics
import CoreImage
import PDFKit
import UniformTypeIdentifiers
import DropShelfCodecs

/// Bild-Konverter über ImageIO, Core Image (RAW), PDFKit (Bild→PDF) und statisch eingebundenes libwebp.
/// Ziele: ImageIO-Ziele aus `CGImageDestinationCopyTypeIdentifiers` (inkl. BMP/AVIF falls unterstützt),
/// `.webP` (über libwebp) sowie `.pdf` (ein Bild pro Seite).
/// SVG-Eingang wird bewusst nicht angeboten (ImageIO liest kein SVG ohne Fremdcode/WebKit).
enum ImageConverter {
    static let avif = UTType("public.avif") ?? UTType(filenameExtension: "avif")!

    /// Gängige Kamera-RAW-Typen, die über `CIRAWFilter` gelesen werden.
    static let rawTypes: [UTType] = {
        var list: [UTType] = [.rawImage]
        for ext in ["dng", "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2", "pef", "srw"] {
            if let t = UTType(filenameExtension: ext), !list.contains(t) { list.append(t) }
        }
        return list
    }()

    static var readable: [UTType] {
        var list: [UTType] = [.heic, .jpeg, .png, .tiff, .gif, .bmp, .webP]
        let srcIDs = (CGImageSourceCopyTypeIdentifiers() as? [String]) ?? []
        if srcIDs.contains(avif.identifier), !list.contains(avif) { list.append(avif) }
        for r in rawTypes where !list.contains(r) { list.append(r) }
        return list
    }

    static var writable: [UTType] {
        let ids = (CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []
        var w: [UTType] = [UTType.heic, .jpeg, .png, .tiff, .gif, .bmp, avif].filter { ids.contains($0.identifier) }
        w.append(.webP)
        w.append(.pdf)
        return w
    }

    static var converter: Converter {
        let w = writable
        let pairs = Set(readable.flatMap { f in w.filter { $0 != f }.map { Conversion(from: f, to: $0) } })
        return Converter(id: "image", pairs: pairs) { src, dst, o in try convert(src, dst, o) }
    }

    private static func loadCGImage(from src: URL, options o: ConvertOptions) throws -> CGImage {
        let fromType = (try? src.resourceValues(forKeys: [.contentTypeKey]))?.contentType
            ?? UTType(filenameExtension: src.pathExtension)
        if fromType?.conforms(to: .rawImage) == true {
            return try loadRAWImage(from: src, scale: o.imageScale)
        }
        guard let source = CGImageSourceCreateWithURL(src as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Double, let h = props[kCGImagePropertyPixelHeight] as? Double
        else { throw ConvertError.unreadable }

        let t = targetSize(CGSize(width: w, height: h), o.imageScale)
        let thumb: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(t.width, t.height),
        ]
        guard let img = CGImageSourceCreateThumbnailAtIndex(source, 0, thumb as CFDictionary) else { throw ConvertError.unreadable }
        return img
    }

    private static func loadRAWImage(from src: URL, scale: ImageScale) throws -> CGImage {
        guard let rawFilter = CIRAWFilter(imageURL: src),
              var ci = rawFilter.outputImage,
              ci.extent.width > 0, ci.extent.height > 0
        else { throw ConvertError.unreadable }

        let target = targetSize(ci.extent.size, scale)
        if target.width < ci.extent.width || target.height < ci.extent.height {
            let factor = min(target.width / ci.extent.width, target.height / ci.extent.height)
            if let scaler = CIFilter(name: "CILanczosScaleTransform") {
                scaler.setValue(ci, forKey: kCIInputImageKey)
                scaler.setValue(factor, forKey: kCIInputScaleKey)
                scaler.setValue(1.0, forKey: kCIInputAspectRatioKey)
                if let scaled = scaler.outputImage { ci = scaled }
            }
        }
        guard let cg = CIContext().createCGImage(ci, from: ci.extent) else { throw ConvertError.unreadable }
        return cg
    }

    /// Flacht Bilder mit Alphakanal auf reinweißem Hintergrund ab (für Zielformate ohne Transparenz wie JPEG/BMP).
    static func flattenToWhite(_ img: CGImage) -> CGImage {
        switch img.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast:
            return img
        default:
            break
        }
        let w = img.width, h = img.height
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return img }
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(rect)
        ctx.draw(img, in: rect)
        return ctx.makeImage() ?? img
    }

    private static func convert(_ src: URL, _ dst: URL, _ o: ConvertOptions) throws {
        let started = src.startAccessingSecurityScopedResource()
        defer { if started { src.stopAccessingSecurityScopedResource() } }
        guard let to = UTType(filenameExtension: dst.pathExtension) else { throw ConvertError.unsupported }

        var img = try loadCGImage(from: src, options: o)

        if to == .webP {
            try writeWebP(img, to: dst, options: o)
            return
        }
        if to == .pdf {
            let nsImg = NSImage(cgImage: img, size: NSSize(width: img.width, height: img.height))
            guard let page = PDFPage(image: nsImg) else { throw ConvertError.writeFailed }
            let doc = PDFDocument()
            doc.insert(page, at: 0)
            guard doc.write(to: dst) else { throw ConvertError.writeFailed }
            return
        }
        if to == .jpeg || to == .bmp {
            img = flattenToWhite(img)
        }

        let fail: ConvertError = to == .heic ? .heicUnavailable : .writeFailed
        guard let dest = CGImageDestinationCreateWithURL(dst as CFURL, to.identifier as CFString, 1, nil) else { throw fail }
        var opts: [CFString: Any] = [:]
        if (to == .jpeg || to == .heic || to == avif), let q = o.quality {
            opts[kCGImageDestinationLossyCompressionQuality] = min(max(q, 0), 1)
        }
        CGImageDestinationAddImage(dest, img, opts as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw fail }
    }

    private static func writeWebP(_ img: CGImage, to dst: URL, options o: ConvertOptions) throws {
        let width = img.width
        let height = img.height
        guard width > 0, height > 0 else { throw ConvertError.unreadable }
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        let ok = rgba.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: space, bitmapInfo: bitmapInfo)
            else { return false }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else { throw ConvertError.writeFailed }
        // Un-premultiply RGBA for libwebp when semi-transparent pixels are present
        for i in stride(from: 0, to: rgba.count, by: 4) {
            let a = rgba[i + 3]
            if a > 0 && a < 255 {
                let alpha = Int(a)
                rgba[i] = UInt8(min(255, (Int(rgba[i]) * 255 + alpha / 2) / alpha))
                rgba[i + 1] = UInt8(min(255, (Int(rgba[i + 1]) * 255 + alpha / 2) / alpha))
                rgba[i + 2] = UInt8(min(255, (Int(rgba[i + 2]) * 255 + alpha / 2) / alpha))
            }
        }
        let lossless = o.preset?.lowercased() == "lossless"
        do {
            try WebPCodec.encodeRGBA(rgba, width: width, height: height,
                                     quality: o.quality.map(Float.init), lossless: lossless, to: dst)
        } catch {
            throw ConvertError.writeFailed
        }
    }
}
