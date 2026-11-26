import Foundation

public struct PCMBuffer: Sendable {
    /// Interleaved 32-bit float PCM samples in [-1.0, 1.0].
    public let samples: [Float]
    public let sampleRate: Int
    public let channels: Int

    public var frameCount: Int {
        channels > 0 ? samples.count / channels : 0
    }

    public var duration: Double {
        sampleRate > 0 ? Double(frameCount) / Double(sampleRate) : 0
    }

    public init(samples: [Float], sampleRate: Int, channels: Int) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.channels = channels
    }

    /// Linearly resamples interleaved float PCM to `targetRate`.
    public func resampled(to targetRate: Int) -> PCMBuffer {
        guard targetRate > 0, sampleRate > 0, targetRate != sampleRate, frameCount > 0 else {
            return self
        }
        let ratio = Double(sampleRate) / Double(targetRate)
        let outFrames = max(1, Int((Double(frameCount) / ratio).rounded()))
        var out = [Float](repeating: 0, count: outFrames * channels)
        let lastFrame = frameCount - 1
        for i in 0..<outFrames {
            let srcPos = Double(i) * ratio
            let idx0 = min(Int(srcPos), lastFrame)
            let idx1 = min(idx0 + 1, lastFrame)
            let frac = Float(srcPos - Double(idx0))
            let base0 = idx0 * channels
            let base1 = idx1 * channels
            let dstBase = i * channels
            for ch in 0..<channels {
                out[dstBase + ch] = samples[base0 + ch] * (1 - frac) + samples[base1 + ch] * frac
            }
        }
        return PCMBuffer(samples: out, sampleRate: targetRate, channels: channels)
    }

    /// Downmixes to stereo if more than 2 channels; mono and stereo pass through unchanged.
    public func clampedToStereo() -> PCMBuffer {
        guard channels > 2, frameCount > 0 else { return self }
        var out = [Float](repeating: 0, count: frameCount * 2)
        for i in 0..<frameCount {
            let base = i * channels
            out[2 * i] = samples[base]
            out[2 * i + 1] = samples[base + 1]
        }
        return PCMBuffer(samples: out, sampleRate: sampleRate, channels: 2)
    }
}

public enum CodecError: Error, LocalizedError, Sendable {
    case invalidInput(String)
    case encodeFailed(String)
    case decodeFailed(String)
    case ioFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidInput(let m): return "Ungültige Eingabe: \(m)"
        case .encodeFailed(let m): return "Kodierung fehlgeschlagen: \(m)"
        case .decodeFailed(let m): return "Dekodierung fehlgeschlagen: \(m)"
        case .ioFailed(let m): return "Dateifehler: \(m)"
        }
    }
}
