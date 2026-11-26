import Foundation
import CWavPack

public enum WavPackCodec {
    private final class OutputAccumulator {
        var data = Data()
    }

    /// Encodes interleaved Float PCM into a 16-bit lossless WavPack (`.wv`) file.
    public static func encode(_ pcm: PCMBuffer, to url: URL) throws {
        guard pcm.channels >= 1, pcm.channels <= 8, pcm.sampleRate > 0, pcm.frameCount > 0 else {
            throw CodecError.invalidInput("WavPack benötigt 1–8 Kanäle und gültige Samplerate")
        }

        let acc = OutputAccumulator()
        let accPtr = Unmanaged.passUnretained(acc).toOpaque()

        let blockOut: WavpackBlockOutput = { id, data, bcount in
            guard let id, let data, bcount > 0 else { return 1 }
            let box = Unmanaged<OutputAccumulator>.fromOpaque(id).takeUnretainedValue()
            box.data.append(data.assumingMemoryBound(to: UInt8.self), count: Int(bcount))
            return 1
        }

        guard let wpc = WavpackOpenFileOutput(blockOut, accPtr, nil) else {
            throw CodecError.encodeFailed("WavpackOpenFileOutput fehlgeschlagen")
        }
        defer { WavpackCloseFile(wpc) }

        var config = WavpackConfig()
        config.bits_per_sample = 16
        config.bytes_per_sample = 2
        config.num_channels = Int32(pcm.channels)
        config.channel_mask = pcm.channels == 1 ? 4 : (pcm.channels == 2 ? 3 : 0)
        config.sample_rate = Int32(pcm.sampleRate)

        guard WavpackSetConfiguration(wpc, &config, UInt32(pcm.frameCount)) != 0,
              WavpackPackInit(wpc) != 0 else {
            throw CodecError.encodeFailed("WavpackSetConfiguration/PackInit fehlgeschlagen")
        }

        let chunkFrames = 4096
        let channels = pcm.channels
        let totalFrames = pcm.frameCount
        var int32Buf = [Int32](repeating: 0, count: chunkFrames * channels)
        var offset = 0

        while offset < totalFrames {
            let count = min(chunkFrames, totalFrames - offset)
            let sampleCount = count * channels
            let base = offset * channels
            for i in 0..<sampleCount {
                let clamped = min(max(pcm.samples[base + i], -1.0), 1.0)
                let scaled = (clamped * 32767.0).rounded()
                int32Buf[i] = Int32(max(-32768.0, min(32767.0, scaled)))
            }
            let ok = int32Buf.withUnsafeMutableBufferPointer { ptr in
                WavpackPackSamples(wpc, ptr.baseAddress, UInt32(count))
            }
            guard ok != 0 else {
                throw CodecError.encodeFailed("WavpackPackSamples fehlgeschlagen")
            }
            offset += count
        }

        guard WavpackFlushSamples(wpc) != 0 else {
            throw CodecError.encodeFailed("WavpackFlushSamples fehlgeschlagen")
        }

        do {
            try acc.data.write(to: url, options: .atomic)
        } catch {
            throw CodecError.ioFailed(error.localizedDescription)
        }
    }

    /// Decodes a WavPack (`.wv`) file into interleaved Float PCM.
    public static func decode(_ url: URL) throws -> PCMBuffer {
        var errBuf = [CChar](repeating: 0, count: 128)
        let wpc = url.path.withCString { cPath in
            WavpackOpenFileInput(cPath, &errBuf, OPEN_NORMALIZE, 0)
        }
        guard let wpc else {
            throw CodecError.decodeFailed("WavpackOpenFileInput fehlgeschlagen")
        }
        defer { WavpackCloseFile(wpc) }

        let channels = Int(WavpackGetNumChannels(wpc))
        let sampleRate = Int(WavpackGetSampleRate(wpc))
        let bits = Int(WavpackGetBitsPerSample(wpc))
        let isFloat = (WavpackGetMode(wpc) & MODE_FLOAT) != 0
        guard channels > 0, sampleRate > 0, bits > 0 else {
            throw CodecError.decodeFailed("Ungültige WavPack-Stream-Parameter")
        }

        let scale: Float = Float(1 << max(bits - 1, 1))
        let chunkFrames: UInt32 = 4096
        var rawBuf = [Int32](repeating: 0, count: Int(chunkFrames) * channels)
        var samples: [Float] = []

        while true {
            let unpacked = rawBuf.withUnsafeMutableBufferPointer { ptr in
                WavpackUnpackSamples(wpc, ptr.baseAddress, chunkFrames)
            }
            if unpacked == 0 { break }
            let count = Int(unpacked) * channels
            samples.reserveCapacity(samples.count + count)
            if isFloat {
                for i in 0..<count {
                    samples.append(Float(bitPattern: UInt32(bitPattern: rawBuf[i])))
                }
            } else {
                for i in 0..<count {
                    samples.append(Float(rawBuf[i]) / scale)
                }
            }
        }

        guard !samples.isEmpty else {
            throw CodecError.decodeFailed("Keine WavPack-Audiodaten gefunden")
        }
        return PCMBuffer(samples: samples, sampleRate: sampleRate, channels: channels)
    }
}
