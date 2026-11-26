import Foundation
import CFlac

public enum FlacCodec {
    /// Encodes interleaved Float PCM into a 16-bit lossless FLAC file using libFLAC.
    public static func encode(_ pcm: PCMBuffer, compressionLevel: UInt32 = 5, to url: URL) throws {
        guard pcm.channels >= 1, pcm.channels <= 8, pcm.sampleRate > 0, pcm.frameCount > 0 else {
            throw CodecError.invalidInput("FLAC benötigt 1–8 Kanäle und gültige Samplerate")
        }
        guard let encoder = FLAC__stream_encoder_new() else {
            throw CodecError.encodeFailed("FLAC__stream_encoder_new fehlgeschlagen")
        }
        defer { FLAC__stream_encoder_delete(encoder) }

        FLAC__stream_encoder_set_verify(encoder, 0)
        FLAC__stream_encoder_set_compression_level(encoder, min(compressionLevel, 8))
        FLAC__stream_encoder_set_channels(encoder, UInt32(pcm.channels))
        FLAC__stream_encoder_set_bits_per_sample(encoder, 16)
        FLAC__stream_encoder_set_sample_rate(encoder, UInt32(pcm.sampleRate))
        FLAC__stream_encoder_set_total_samples_estimate(encoder, UInt64(pcm.frameCount))

        let initStatus = url.path.withCString { cPath in
            FLAC__stream_encoder_init_file(encoder, cPath, nil, nil)
        }
        guard initStatus == FLAC__STREAM_ENCODER_INIT_STATUS_OK else {
            throw CodecError.encodeFailed("FLAC__stream_encoder_init_file fehlgeschlagen (\(initStatus.rawValue))")
        }

        let chunkFrames = 4096
        let channels = pcm.channels
        let totalFrames = pcm.frameCount
        var int32Buf = [FLAC__int32](repeating: 0, count: chunkFrames * channels)
        var offset = 0

        while offset < totalFrames {
            let count = min(chunkFrames, totalFrames - offset)
            let sampleCount = count * channels
            let base = offset * channels
            for i in 0..<sampleCount {
                let clamped = min(max(pcm.samples[base + i], -1.0), 1.0)
                let scaled = (clamped * 32767.0).rounded()
                int32Buf[i] = FLAC__int32(max(-32768.0, min(32767.0, scaled)))
            }
            let ok = int32Buf.withUnsafeBufferPointer { ptr in
                FLAC__stream_encoder_process_interleaved(encoder, ptr.baseAddress, UInt32(count))
            }
            guard ok != 0 else {
                throw CodecError.encodeFailed("FLAC__stream_encoder_process_interleaved fehlgeschlagen")
            }
            offset += count
        }

        guard FLAC__stream_encoder_finish(encoder) != 0 else {
            throw CodecError.encodeFailed("FLAC__stream_encoder_finish fehlgeschlagen")
        }
    }
}
