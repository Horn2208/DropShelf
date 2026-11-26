import Foundation
import CLame

public enum Mp3Codec {
    /// Encodes interleaved Float PCM into an MP3 file using libmp3lame (VBR).
    /// `quality` is in `0.0...1.0` (1.0 = highest quality V0, 0.0 = smallest V9; default ~V2).
    public static func encode(_ pcm: PCMBuffer, quality: Double? = nil, to url: URL) throws {
        guard pcm.channels >= 1, pcm.sampleRate >= 8000, pcm.frameCount > 0 else {
            throw CodecError.invalidInput("MP3 benötigt mindestens 1 Kanal und >= 8 kHz")
        }
        let prepared = pcm.clampedToStereo()
        let channels = prepared.channels
        let totalFrames = prepared.frameCount

        guard let gfp = lame_init() else {
            throw CodecError.encodeFailed("lame_init fehlgeschlagen")
        }
        defer { lame_close(gfp) }

        lame_set_num_channels(gfp, Int32(channels))
        lame_set_in_samplerate(gfp, Int32(prepared.sampleRate))
        lame_set_mode(gfp, channels == 1 ? MONO : JOINT_STEREO)
        lame_set_VBR(gfp, vbr_default)
        let vbrQ: Int32 = quality.map { Int32(((1.0 - min(max($0, 0), 1)) * 9.0).rounded()) } ?? 2
        lame_set_VBR_q(gfp, vbrQ)
        lame_set_bWriteVbrTag(gfp, 1)

        guard lame_init_params(gfp) >= 0 else {
            throw CodecError.encodeFailed("lame_init_params fehlgeschlagen")
        }

        let chunkFrames = 4096
        let mp3BufSize = Int(Double(chunkFrames) * 1.25 + 7200)
        var mp3Buf = [UInt8](repeating: 0, count: mp3BufSize)
        var left = [Float](repeating: 0, count: chunkFrames)
        var right = [Float](repeating: 0, count: chunkFrames)
        var output = Data()

        var offset = 0
        while offset < totalFrames {
            let count = min(chunkFrames, totalFrames - offset)
            if channels == 1 {
                for i in 0..<count {
                    left[i] = prepared.samples[offset + i]
                }
                let written = lame_encode_buffer_ieee_float(gfp, &left, nil, Int32(count), &mp3Buf, Int32(mp3BufSize))
                guard written >= 0 else {
                    throw CodecError.encodeFailed("lame_encode_buffer_ieee_float fehlgeschlagen (\(written))")
                }
                if written > 0 { output.append(contentsOf: mp3Buf[0..<Int(written)]) }
            } else {
                for i in 0..<count {
                    let base = (offset + i) * 2
                    left[i] = prepared.samples[base]
                    right[i] = prepared.samples[base + 1]
                }
                let written = lame_encode_buffer_ieee_float(gfp, &left, &right, Int32(count), &mp3Buf, Int32(mp3BufSize))
                guard written >= 0 else {
                    throw CodecError.encodeFailed("lame_encode_buffer_ieee_float fehlgeschlagen (\(written))")
                }
                if written > 0 { output.append(contentsOf: mp3Buf[0..<Int(written)]) }
            }
            offset += count
        }

        let flushed = lame_encode_flush(gfp, &mp3Buf, Int32(mp3BufSize))
        guard flushed >= 0 else {
            throw CodecError.encodeFailed("lame_encode_flush fehlgeschlagen (\(flushed))")
        }
        if flushed > 0 { output.append(contentsOf: mp3Buf[0..<Int(flushed)]) }

        // Patch Xing/LAME VBR header at frame 0 for exact duration reporting
        var vbrTag = [UInt8](repeating: 0, count: 4096)
        let tagLen = lame_get_lametag_frame(gfp, &vbrTag, vbrTag.count)
        if tagLen > 0, tagLen <= vbrTag.count, tagLen <= output.count {
            output.replaceSubrange(0..<tagLen, with: vbrTag[0..<tagLen])
        }

        do {
            try output.write(to: url, options: .atomic)
        } catch {
            throw CodecError.ioFailed(error.localizedDescription)
        }
    }
}
