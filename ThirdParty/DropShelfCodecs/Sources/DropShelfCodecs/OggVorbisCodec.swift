import Foundation
import COgg
import CVorbis

public enum OggVorbisCodec {
    /// Checks whether an Ogg file's first packet starts with `OpusHead`.
    public static func isOggOpus(_ url: URL) -> Bool {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? fh.close() }
        guard let head = try? fh.read(upToCount: 64), head.count >= 36 else { return false }
        // Ogg page header: "OggS" at 0..3, page_segments at byte 26, segment table starts at 27.
        guard head[0] == 0x4F, head[1] == 0x67, head[2] == 0x67, head[3] == 0x53 else { return false }
        let segCount = Int(head[26])
        let payloadOffset = 27 + segCount
        guard head.count >= payloadOffset + 8 else { return false }
        let magic = Data("OpusHead".utf8)
        return head[payloadOffset..<(payloadOffset + 8)] == magic
    }

    /// Encodes interleaved Float PCM into an Ogg Vorbis file.
    /// `quality` is in `0.0...1.0` (mapped to libvorbis `-0.1...1.0`, default `0.5`).
    public static func encode(_ pcm: PCMBuffer, quality: Float = 0.5, to url: URL) throws {
        guard pcm.channels >= 1, pcm.channels <= 8, pcm.sampleRate >= 8000, pcm.frameCount > 0 else {
            throw CodecError.invalidInput("Ogg Vorbis benötigt 1–8 Kanäle und >= 8 kHz")
        }

        var vi = vorbis_info()
        vorbis_info_init(&vi)
        defer { vorbis_info_clear(&vi) }

        let q = min(max(quality, 0.0), 1.0)
        guard vorbis_encode_init_vbr(&vi, pcm.channels, pcm.sampleRate, q) == 0 else {
            throw CodecError.encodeFailed("vorbis_encode_init_vbr fehlgeschlagen")
        }

        var vc = vorbis_comment()
        vorbis_comment_init(&vc)
        defer { vorbis_comment_clear(&vc) }
        "ENCODER".withCString { k in
            "DropShelf".withCString { v in
                vorbis_comment_add_tag(&vc, k, v)
            }
        }

        var vd = vorbis_dsp_state()
        guard vorbis_analysis_init(&vd, &vi) == 0 else {
            throw CodecError.encodeFailed("vorbis_analysis_init fehlgeschlagen")
        }
        defer { vorbis_dsp_clear(&vd) }

        var vb = vorbis_block()
        guard vorbis_block_init(&vd, &vb) == 0 else {
            throw CodecError.encodeFailed("vorbis_block_init fehlgeschlagen")
        }
        defer { vorbis_block_clear(&vb) }

        var os = ogg_stream_state()
        let serial = Int32(bitPattern: UInt32.random(in: 1...UInt32.max))
        guard ogg_stream_init(&os, serial) == 0 else {
            throw CodecError.encodeFailed("ogg_stream_init fehlgeschlagen")
        }
        defer { ogg_stream_clear(&os) }

        var header = ogg_packet()
        var headerComm = ogg_packet()
        var headerCode = ogg_packet()
        vorbis_analysis_headerout(&vd, &vc, &header, &headerComm, &headerCode)
        ogg_stream_packetin(&os, &header)
        ogg_stream_packetin(&os, &headerComm)
        ogg_stream_packetin(&os, &headerCode)

        var output = Data()
        var og = ogg_page()
        while ogg_stream_flush(&os, &og) != 0 {
            output.append(og.header, count: og.header_len)
            output.append(og.body, count: og.body_len)
        }

        let chunkSize = 4096
        let totalFrames = pcm.frameCount
        let channels = pcm.channels
        var offset = 0

        func drainBlocks() {
            var op = ogg_packet()
            while vorbis_analysis_blockout(&vd, &vb) == 1 {
                vorbis_analysis(&vb, nil)
                vorbis_bitrate_addblock(&vb)
                while vorbis_bitrate_flushpacket(&vd, &op) != 0 {
                    ogg_stream_packetin(&os, &op)
                    while ogg_stream_pageout(&os, &og) != 0 {
                        output.append(og.header, count: og.header_len)
                        output.append(og.body, count: og.body_len)
                    }
                }
            }
        }

        while offset < totalFrames {
            let count = min(chunkSize, totalFrames - offset)
            guard let buffers = vorbis_analysis_buffer(&vd, Int32(count)) else {
                throw CodecError.encodeFailed("vorbis_analysis_buffer fehlgeschlagen")
            }
            for ch in 0..<channels {
                guard let chBuf = buffers[ch] else { continue }
                for i in 0..<count {
                    chBuf[i] = pcm.samples[(offset + i) * channels + ch]
                }
            }
            vorbis_analysis_wrote(&vd, Int32(count))
            drainBlocks()
            offset += count
        }

        vorbis_analysis_wrote(&vd, 0)
        drainBlocks()

        while ogg_stream_flush(&os, &og) != 0 {
            output.append(og.header, count: og.header_len)
            output.append(og.body, count: og.body_len)
        }

        do {
            try output.write(to: url, options: .atomic)
        } catch {
            throw CodecError.ioFailed(error.localizedDescription)
        }
    }

    /// Decodes an Ogg Vorbis file into interleaved Float PCM.
    public static func decode(_ url: URL) throws -> PCMBuffer {
        var vf = OggVorbis_File()
        let openStatus = url.path.withCString { cPath in
            ov_fopen(cPath, &vf)
        }
        guard openStatus == 0 else {
            throw CodecError.decodeFailed("ov_fopen fehlgeschlagen (\(openStatus))")
        }
        defer { ov_clear(&vf) }

        guard let info = ov_info(&vf, -1)?.pointee else {
            throw CodecError.decodeFailed("ov_info fehlgeschlagen")
        }
        let channels = Int(info.channels)
        let sampleRate = Int(info.rate)
        guard channels > 0, sampleRate > 0 else {
            throw CodecError.decodeFailed("Ungültige Vorbis-Stream-Parameter")
        }

        var samples: [Float] = []
        var pcmPtr: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>?
        var bitstream: Int32 = 0
        while true {
            let framesRead = ov_read_float(&vf, &pcmPtr, 4096, &bitstream)
            if framesRead == 0 { break }
            if framesRead < 0 {
                throw CodecError.decodeFailed("ov_read_float Fehler \(framesRead)")
            }
            guard let chPtrs = pcmPtr else { continue }
            let n = Int(framesRead)
            samples.reserveCapacity(samples.count + n * channels)
            for i in 0..<n {
                for ch in 0..<channels {
                    samples.append(chPtrs[ch]?[i] ?? 0)
                }
            }
        }
        return PCMBuffer(samples: samples, sampleRate: sampleRate, channels: channels)
    }
}
