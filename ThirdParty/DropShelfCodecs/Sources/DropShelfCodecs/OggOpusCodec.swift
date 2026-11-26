import Foundation
import COgg
import COpus

/// RFC 7845 Ogg Opus encoder and decoder using libopus + libogg.
public enum OggOpusCodec {
    private static let opusRate = 48_000
    private static let frameSamples = 960 // 20 ms @ 48 kHz

    public static func encode(_ pcm: PCMBuffer, bitrate: Int32 = 128_000, to url: URL) throws {
        guard pcm.channels >= 1, pcm.sampleRate >= 8000, pcm.frameCount > 0 else {
            throw CodecError.invalidInput("Opus benötigt mindestens 1 Kanal und >= 8 kHz")
        }
        let inputRate = UInt32(pcm.sampleRate)
        let prepared = pcm.clampedToStereo().resampled(to: opusRate)
        let channels = prepared.channels
        let totalFrames = prepared.frameCount

        var err: Int32 = 0
        guard let enc = opus_encoder_create(Int32(opusRate), Int32(channels), OPUS_APPLICATION_AUDIO, &err),
              err == OPUS_OK else {
            throw CodecError.encodeFailed("opus_encoder_create fehlgeschlagen (\(err))")
        }
        defer { opus_encoder_destroy(enc) }

        _ = dropshelf_opus_set_bitrate(enc, bitrate)
        var lookahead: Int32 = 312
        _ = dropshelf_opus_get_lookahead(enc, &lookahead)
        let preSkip = UInt16(max(0, lookahead))

        var os = ogg_stream_state()
        let serial = Int32(bitPattern: UInt32.random(in: 1...UInt32.max))
        guard ogg_stream_init(&os, serial) == 0 else {
            throw CodecError.encodeFailed("ogg_stream_init fehlgeschlagen")
        }
        defer { ogg_stream_clear(&os) }

        var output = Data()
        var og = ogg_page()
        var packetNo: Int64 = 0

        func submitPacket(_ data: Data, b_o_s: Int, e_o_s: Int, granulePos: Int64, forceFlush: Bool) {
            var bytes = [UInt8](data)
            bytes.withUnsafeMutableBufferPointer { buf in
                var op = ogg_packet()
                op.packet = buf.baseAddress
                op.bytes = buf.count
                op.b_o_s = b_o_s
                op.e_o_s = e_o_s
                op.granulepos = granulePos
                op.packetno = packetNo
                packetNo += 1
                ogg_stream_packetin(&os, &op)
                if forceFlush {
                    while ogg_stream_flush(&os, &og) != 0 {
                        output.append(og.header, count: og.header_len)
                        output.append(og.body, count: og.body_len)
                    }
                } else {
                    while ogg_stream_pageout(&os, &og) != 0 {
                        output.append(og.header, count: og.header_len)
                        output.append(og.body, count: og.body_len)
                    }
                }
            }
        }

        // Packet 0: OpusHead (RFC 7845 Section 5.1)
        var head = Data("OpusHead".utf8)
        head.append(1) // version
        head.append(UInt8(channels))
        appendLE(&head, preSkip)
        appendLE(&head, inputRate)
        appendLE(&head, Int16(0)) // output gain
        head.append(0) // channel mapping family 0
        submitPacket(head, b_o_s: 1, e_o_s: 0, granulePos: 0, forceFlush: true)

        // Packet 1: OpusTags (RFC 7845 Section 5.2)
        let vendor = Data("DropShelf".utf8)
        var tags = Data("OpusTags".utf8)
        appendLE(&tags, UInt32(vendor.count))
        tags.append(vendor)
        appendLE(&tags, UInt32(0)) // user comment list length
        submitPacket(tags, b_o_s: 0, e_o_s: 0, granulePos: 0, forceFlush: true)

        // Encode audio packets (include preSkip trailing frames so decoder flushes lookahead)
        let paddedFrames = totalFrames + Int(preSkip)
        let packetCount = max(1, (paddedFrames + frameSamples - 1) / frameSamples)
        var frameBuf = [Float](repeating: 0, count: frameSamples * channels)
        var encBuf = [UInt8](repeating: 0, count: 4000)

        for p in 0..<packetCount {
            let startFrame = p * frameSamples
            for i in 0..<frameSamples {
                let srcFrame = startFrame + i
                if srcFrame < totalFrames {
                    for ch in 0..<channels {
                        frameBuf[i * channels + ch] = prepared.samples[srcFrame * channels + ch]
                    }
                } else {
                    for ch in 0..<channels {
                        frameBuf[i * channels + ch] = 0
                    }
                }
            }

            let encodedBytes = opus_encode_float(enc, &frameBuf, Int32(frameSamples), &encBuf, Int32(encBuf.count))
            guard encodedBytes >= 0 else {
                throw CodecError.encodeFailed("opus_encode_float fehlgeschlagen (\(encodedBytes))")
            }

            let isLast = (p == packetCount - 1)
            let granule: Int64 = isLast ? Int64(totalFrames + Int(preSkip)) : Int64((p + 1) * frameSamples)
            submitPacket(Data(encBuf[0..<Int(encodedBytes)]), b_o_s: 0, e_o_s: isLast ? 1 : 0, granulePos: granule, forceFlush: isLast)
        }

        do {
            try output.write(to: url, options: .atomic)
        } catch {
            throw CodecError.ioFailed(error.localizedDescription)
        }
    }

    public static func decode(_ url: URL) throws -> PCMBuffer {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw CodecError.ioFailed(error.localizedDescription)
        }

        var oy = ogg_sync_state()
        ogg_sync_init(&oy)
        defer { ogg_sync_clear(&oy) }

        var os = ogg_stream_state()
        var streamInitialized = false
        defer { if streamInitialized { ogg_stream_clear(&os) } }

        var decoder: OpaquePointer?
        defer { if let d = decoder { opus_decoder_destroy(d) } }

        var channels = 0
        var preSkip = 0
        var headerPacketsSeen = 0
        var lastGranule: Int64 = -1
        var samples: [Float] = []
        var decodeBuf: [Float] = []

        // Feed full file into ogg_sync_state
        let bufPtr = ogg_sync_buffer(&oy, data.count)
        guard let dst = bufPtr else {
            throw CodecError.decodeFailed("ogg_sync_buffer fehlgeschlagen")
        }
        data.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                memcpy(dst, base, data.count)
            }
        }
        ogg_sync_wrote(&oy, data.count)

        var og = ogg_page()
        var op = ogg_packet()
        let maxFrameSize = 5760 // 120 ms @ 48 kHz

        while ogg_sync_pageout(&oy, &og) == 1 {
            if !streamInitialized {
                ogg_stream_init(&os, ogg_page_serialno(&og))
                streamInitialized = true
            }
            let pageGranule = ogg_page_granulepos(&og)
            if pageGranule >= 0 { lastGranule = pageGranule }

            ogg_stream_pagein(&os, &og)
            while ogg_stream_packetout(&os, &op) == 1 {
                guard let pktPtr = op.packet, op.bytes > 0 else { continue }
                let pkt = Data(bytes: pktPtr, count: op.bytes)

                if headerPacketsSeen == 0 {
                    guard pkt.count >= 19, pkt.starts(with: Data("OpusHead".utf8)) else {
                        throw CodecError.decodeFailed("Ungültiger OpusHead-Header")
                    }
                    channels = Int(pkt[9])
                    preSkip = Int(UInt16(pkt[10]) | (UInt16(pkt[11]) << 8))
                    guard channels >= 1, channels <= 2 else {
                        throw CodecError.decodeFailed("Nicht unterstützte Opus-Kanalzahl: \(channels)")
                    }
                    var err: Int32 = 0
                    guard let d = opus_decoder_create(Int32(opusRate), Int32(channels), &err), err == OPUS_OK else {
                        throw CodecError.decodeFailed("opus_decoder_create fehlgeschlagen (\(err))")
                    }
                    decoder = d
                    decodeBuf = [Float](repeating: 0, count: maxFrameSize * channels)
                    headerPacketsSeen = 1
                } else if headerPacketsSeen == 1 {
                    headerPacketsSeen = 2 // OpusTags
                } else {
                    guard let d = decoder else { continue }
                    let n = opus_decode_float(d, pktPtr, Int32(op.bytes), &decodeBuf, Int32(maxFrameSize), 0)
                    guard n >= 0 else {
                        throw CodecError.decodeFailed("opus_decode_float fehlgeschlagen (\(n))")
                    }
                    samples.append(contentsOf: decodeBuf[0..<(Int(n) * channels)])
                }
            }
        }

        guard channels > 0, !samples.isEmpty else {
            throw CodecError.decodeFailed("Keine Opus-Audiodaten gefunden")
        }

        // Trim preSkip from start and trailing padding using final granulepos
        let totalDecodedFrames = samples.count / channels
        let startFrame = min(preSkip, totalDecodedFrames)
        var endFrame = totalDecodedFrames
        if lastGranule > 0 {
            endFrame = min(endFrame, Int(lastGranule))
        }
        if endFrame < startFrame { endFrame = startFrame }
        let trimmed = Array(samples[(startFrame * channels)..<(endFrame * channels)])
        return PCMBuffer(samples: trimmed, sampleRate: opusRate, channels: channels)
    }

    private static func appendLE<T: FixedWidthInteger>(_ data: inout Data, _ value: T) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }
}
