import Foundation
import CWebP

public enum WebPCodec {
    /// Encodes straight (non-premultiplied) RGBA8888 pixel data to a WebP file using libwebp.
    /// `quality` is in `0.0...1.0` (default `0.8` = WebP quality 80).
    public static func encodeRGBA(_ rgba: [UInt8], width: Int, height: Int,
                                  quality: Float? = nil, lossless: Bool = false, to url: URL) throws {
        guard width > 0, height > 0, rgba.count >= width * height * 4 else {
            throw CodecError.invalidInput("Ungültige RGBA-Bilddaten für WebP")
        }
        let stride = Int32(width * 4)
        var outPtr: UnsafeMutablePointer<UInt8>?
        let outSize: Int = rgba.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return 0 }
            if lossless {
                return WebPEncodeLosslessRGBA(base, Int32(width), Int32(height), stride, &outPtr)
            } else {
                let q = Float(min(max(quality ?? 0.8, 0.0), 1.0)) * 100.0
                return WebPEncodeRGBA(base, Int32(width), Int32(height), stride, q, &outPtr)
            }
        }
        guard outSize > 0, let ptr = outPtr else {
            throw CodecError.encodeFailed("WebPEncodeRGBA fehlgeschlagen")
        }
        defer { WebPFree(ptr) }
        let data = Data(bytes: ptr, count: outSize)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw CodecError.ioFailed(error.localizedDescription)
        }
    }
}
