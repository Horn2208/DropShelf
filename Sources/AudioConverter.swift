import Foundation
import AVFoundation
import AudioToolbox
import UniformTypeIdentifiers
import DropShelfCodecs

/// Audio-Konverter über AVAudioFile und statisch eingebundene Encoder (libogg/libvorbis/libopus/libFLAC/libmp3lame/libwavpack).
/// Ziel m4a: AAC, ALAC oder HE-AAC je nach `ConvertOptions.preset` ("aac" = Standard, "alac", "heaac" falls Encoder vorhanden).
/// Ziel caf: Linear PCM oder Opus je nach `ConvertOptions.preset` ("lpcm" = Standard, "opus" falls Encoder vorhanden).
/// Ziel ogg: Vorbis oder Opus je nach `ConvertOptions.preset` ("vorbis" = Standard, "opus").
/// Ziel flac: verlustfrei über libFLAC (immer verfügbar, unabhängig vom System-Encoder).
/// Ziel mp3: VBR über libmp3lame (`ConvertOptions.quality` 0.0…1.0, Standard ~V2).
/// Ziel wv: verlustfrei über libwavpack.
enum AudioConverter {
    static let caf = UTType("com.apple.coreaudio-format")!
    static let flac = UTType("org.xiph.flac")!
    /// `.mpeg4Audio` hätte die Endung „mp4“; m4a ist ein eigener Typ.
    static let m4a = UTType("com.apple.m4a-audio")!
    static let ogg = UTType("org.xiph.ogg-audio") ?? UTType(filenameExtension: "ogg")!
    static let opus = UTType("org.xiph.opus") ?? UTType(filenameExtension: "opus")!
    static let wavpack = UTType(filenameExtension: "wv")!

    static let readable: [UTType] = {
        var list: [UTType] = [.mp3, .wav, .aiff, caf, m4a, flac, ogg, wavpack]
        if !list.contains(opus) { list.append(opus) }
        return list
    }()
    static let writable: [UTType] = [.wav, .aiff, caf, m4a, flac, ogg, .mp3, wavpack]

    /// Zur Laufzeit von AudioToolbox gemeldete Encoder-Format-IDs.
    static var availableEncodeFormatIDs: Set<AudioFormatID> {
        var size: UInt32 = 0
        guard AudioFormatGetPropertyInfo(kAudioFormatProperty_EncodeFormatIDs, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioFormatID>.size
        var ids = [AudioFormatID](repeating: 0, count: count)
        guard AudioFormatGetProperty(kAudioFormatProperty_EncodeFormatIDs, 0, nil, &size, &ids) == noErr else { return [] }
        return Set(ids)
    }

    static var supportsHEAAC: Bool { availableEncodeFormatIDs.contains(kAudioFormatMPEG4AAC_HE) }
    static var supportsCAFOpus: Bool { availableEncodeFormatIDs.contains(kAudioFormatOpus) }

    /// Verfügbare Presets für ein Zielformat auf diesem Mac.
    static func availablePresets(for target: UTType) -> [String] {
        switch target {
        case m4a: return ["aac", "alac"] + (supportsHEAAC ? ["heaac"] : [])
        case caf: return ["lpcm"] + (supportsCAFOpus ? ["opus"] : [])
        case ogg: return ["vorbis", "opus"]
        default: return []
        }
    }

    static var converter: Converter {
        let pairs = Set(readable.flatMap { f in writable.filter { $0 != f }.map { Conversion(from: f, to: $0) } })
        return Converter(id: "audio", pairs: pairs) { src, dst, o in
            try await Task.detached { try convert(src, dst, o) }.value
        }
    }

    private static func opusSampleRate(for rate: Double) -> Double {
        let valid: [Double] = [8000, 12000, 16000, 24000, 48000]
        return valid.first { $0 >= rate } ?? 48000
    }

    private static func settings(_ to: UTType, _ preset: String?, rate: Double, channels: Int) throws -> [String: Any] {
        var s: [String: Any] = [AVSampleRateKey: rate, AVNumberOfChannelsKey: channels]
        func lpcm(bigEndian: Bool) {
            s[AVFormatIDKey] = kAudioFormatLinearPCM
            s[AVLinearPCMBitDepthKey] = 16
            s[AVLinearPCMIsFloatKey] = false
            s[AVLinearPCMIsBigEndianKey] = bigEndian
        }
        let p = preset?.lowercased()
        switch to {
        case .wav: lpcm(bigEndian: false)
        case .aiff: lpcm(bigEndian: true)
        case caf:
            if p == "opus" {
                guard supportsCAFOpus else { throw ConvertError.unsupported }
                s[AVFormatIDKey] = kAudioFormatOpus
                s[AVSampleRateKey] = opusSampleRate(for: rate)
                s[AVEncoderBitRateKey] = 64_000 * max(1, min(channels, 2))
            } else {
                lpcm(bigEndian: false)
            }
        default:
            if p == "alac" {
                s[AVFormatIDKey] = kAudioFormatAppleLossless
                s[AVEncoderBitDepthHintKey] = 16
            } else if p == "heaac" {
                guard supportsHEAAC else { throw ConvertError.unsupported }
                s[AVFormatIDKey] = kAudioFormatMPEG4AAC_HE
                s[AVEncoderBitRateKey] = 64_000 * channels / (channels > 1 ? 2 : 1)
            } else {
                s[AVFormatIDKey] = kAudioFormatMPEG4AAC
                s[AVEncoderBitRateKey] = 128_000 * channels / (channels > 1 ? 2 : 1)
            }
        }
        return s
    }

    private static func isOggExtension(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "ogg" || ext == "opus" || ext == "oga"
    }

    private static func isWavPackExtension(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "wv"
    }

    private static func readPCM(_ src: URL) throws -> PCMBuffer {
        if isOggExtension(src) {
            do {
                return OggVorbisCodec.isOggOpus(src) ? try OggOpusCodec.decode(src) : try OggVorbisCodec.decode(src)
            } catch {
                throw ConvertError.unreadable
            }
        }
        if isWavPackExtension(src) {
            do {
                return try WavPackCodec.decode(src)
            } catch {
                throw ConvertError.unreadable
            }
        }
        guard let input = try? AVAudioFile(forReading: src) else { throw ConvertError.unreadable }
        let inFmt = input.processingFormat
        let channels = Int(inFmt.channelCount)
        let rate = Int(inFmt.sampleRate.rounded())
        guard channels > 0, rate > 0,
              let floatFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inFmt.sampleRate,
                                           channels: inFmt.channelCount, interleaved: true),
              let buf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: 32768)
        else { throw ConvertError.unreadable }

        let converter = (inFmt != floatFmt) ? AVAudioConverter(from: inFmt, to: floatFmt) : nil
        var samples: [Float] = []
        samples.reserveCapacity(Int(input.length) * channels)

        while input.framePosition < input.length {
            try input.read(into: buf)
            if buf.frameLength == 0 { break }
            if let conv = converter {
                guard let outBuf = AVAudioPCMBuffer(pcmFormat: floatFmt, frameCapacity: buf.frameLength) else {
                    throw ConvertError.unreadable
                }
                nonisolated(unsafe) var provided = false
                nonisolated(unsafe) let srcBuf = buf
                var err: NSError?
                conv.convert(to: outBuf, error: &err) { _, status in
                    if provided { status.pointee = .noDataNow; return nil }
                    provided = true
                    status.pointee = .haveData
                    return srcBuf
                }
                if err != nil { throw ConvertError.unreadable }
                if let ptr = outBuf.floatChannelData?[0] {
                    let count = Int(outBuf.frameLength) * channels
                    samples.append(contentsOf: UnsafeBufferPointer(start: ptr, count: count))
                }
            } else if let ptr = buf.floatChannelData?[0] {
                let count = Int(buf.frameLength) * channels
                samples.append(contentsOf: UnsafeBufferPointer(start: ptr, count: count))
            }
        }
        guard !samples.isEmpty else { throw ConvertError.unreadable }
        return PCMBuffer(samples: samples, sampleRate: rate, channels: channels)
    }

    private static func writeAVAudio(_ pcm: PCMBuffer, to dst: URL, as to: UTType, preset: String?) throws {
        guard let inFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(pcm.sampleRate),
                                        channels: AVAudioChannelCount(pcm.channels), interleaved: true)
        else { throw ConvertError.writeFailed }
        let s = try settings(to, preset, rate: Double(pcm.sampleRate), channels: pcm.channels)
        let targetRate = (s[AVSampleRateKey] as? Double) ?? Double(pcm.sampleRate)
        do {
            guard let output = try? AVAudioFile(forWriting: dst, settings: s, commonFormat: .pcmFormatFloat32, interleaved: true)
            else { throw ConvertError.writeFailed }
            if abs(targetRate - Double(pcm.sampleRate)) > 0.5 {
                guard let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: targetRate,
                                                 channels: AVAudioChannelCount(pcm.channels), interleaved: true),
                      let conv = AVAudioConverter(from: inFmt, to: outFmt)
                else { throw ConvertError.writeFailed }
                let chunkFrames = 32768
                let outCap = AVAudioFrameCount((Double(chunkFrames) * targetRate / Double(pcm.sampleRate)).rounded(.up) + 1024)
                guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: AVAudioFrameCount(chunkFrames)),
                      let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: outCap)
                else { throw ConvertError.writeFailed }
                nonisolated(unsafe) var offset = 0
                let total = pcm.frameCount
                nonisolated(unsafe) let readBuf = inBuf
                while true {
                    var err: NSError?
                    outBuf.frameLength = 0
                    let status = conv.convert(to: outBuf, error: &err) { _, outStatus in
                        if offset >= total { outStatus.pointee = .endOfStream; return nil }
                        let count = min(chunkFrames, total - offset)
                        readBuf.frameLength = AVAudioFrameCount(count)
                        if let dstPtr = readBuf.floatChannelData?[0] {
                            let sampleCount = count * pcm.channels
                            let base = offset * pcm.channels
                            pcm.samples.withUnsafeBufferPointer { src in
                                guard let p = src.baseAddress else { return }
                                dstPtr.update(from: p.advanced(by: base), count: sampleCount)
                            }
                        }
                        offset += count
                        outStatus.pointee = .haveData
                        return readBuf
                    }
                    if err != nil { throw ConvertError.writeFailed }
                    if outBuf.frameLength > 0 { try output.write(from: outBuf) }
                    if status == .endOfStream || status == .error { break }
                }
            } else {
                let chunkFrames = 32768
                var offset = 0
                let total = pcm.frameCount
                while offset < total {
                    let count = min(chunkFrames, total - offset)
                    guard let buf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: AVAudioFrameCount(count)),
                          let dstPtr = buf.floatChannelData?[0] else { throw ConvertError.writeFailed }
                    buf.frameLength = AVAudioFrameCount(count)
                    let sampleCount = count * pcm.channels
                    let base = offset * pcm.channels
                    pcm.samples.withUnsafeBufferPointer { src in
                        guard let p = src.baseAddress else { return }
                        dstPtr.update(from: p.advanced(by: base), count: sampleCount)
                    }
                    try output.write(from: buf)
                    offset += count
                }
            }
        }
    }

    private static func writeResampled(_ input: AVAudioFile, to output: AVAudioFile, targetRate: Double) throws {
        let inFmt = input.processingFormat
        guard let outFmt = AVAudioFormat(commonFormat: inFmt.commonFormat, sampleRate: targetRate,
                                         channels: inFmt.channelCount, interleaved: inFmt.isInterleaved),
              let conv = AVAudioConverter(from: inFmt, to: outFmt),
              let inBuf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: 32768)
        else { throw ConvertError.writeFailed }
        let outCap = AVAudioFrameCount((32768.0 * targetRate / inFmt.sampleRate).rounded(.up) + 1024)
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: outCap) else { throw ConvertError.writeFailed }
        nonisolated(unsafe) var eof = false
        nonisolated(unsafe) let srcFile = input
        nonisolated(unsafe) let readBuf = inBuf
        while !eof {
            var err: NSError?
            outBuf.frameLength = 0
            let status = conv.convert(to: outBuf, error: &err) { _, outStatus in
                if eof { outStatus.pointee = .endOfStream; return nil }
                do {
                    try srcFile.read(into: readBuf)
                    if readBuf.frameLength == 0 {
                        eof = true
                        outStatus.pointee = .endOfStream
                        return nil
                    }
                    outStatus.pointee = .haveData
                    return readBuf
                } catch {
                    eof = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
            }
            if err != nil { throw ConvertError.writeFailed }
            if outBuf.frameLength > 0 { try output.write(from: outBuf) }
            if status == .endOfStream || status == .error { break }
        }
    }

    private static func convert(_ src: URL, _ dst: URL, _ o: ConvertOptions) throws {
        let started = src.startAccessingSecurityScopedResource()
        defer { if started { src.stopAccessingSecurityScopedResource() } }
        guard let to = UTType(filenameExtension: dst.pathExtension), writable.contains(to) else { throw ConvertError.unsupported }

        if to == .mp3 {
            let pcm = try readPCM(src)
            do {
                try Mp3Codec.encode(pcm, quality: o.quality, to: dst)
            } catch {
                throw ConvertError.writeFailed
            }
        } else if to == flac {
            let pcm = try readPCM(src)
            do {
                try FlacCodec.encode(pcm, to: dst)
            } catch {
                throw ConvertError.writeFailed
            }
        } else if to == ogg {
            let pcm = try readPCM(src)
            do {
                if o.preset?.lowercased() == "opus" {
                    let bitrate: Int32 = o.quality.map { Int32(32_000 + min(max($0, 0), 1) * 224_000) } ?? 128_000
                    try OggOpusCodec.encode(pcm, bitrate: bitrate, to: dst)
                } else {
                    let quality: Float = o.quality.map(Float.init) ?? 0.5
                    try OggVorbisCodec.encode(pcm, quality: quality, to: dst)
                }
            } catch {
                throw ConvertError.writeFailed
            }
        } else if to == wavpack {
            let pcm = try readPCM(src)
            do {
                try WavPackCodec.encode(pcm, to: dst)
            } catch {
                throw ConvertError.writeFailed
            }
        } else if isOggExtension(src) || isWavPackExtension(src) {
            let pcm = try readPCM(src)
            try writeAVAudio(pcm, to: dst, as: to, preset: o.preset)
        } else {
            guard let input = try? AVAudioFile(forReading: src) else { throw ConvertError.unreadable }
            let fmt = input.processingFormat
            let s = try settings(to, o.preset, rate: fmt.sampleRate, channels: Int(fmt.channelCount))
            let targetRate = (s[AVSampleRateKey] as? Double) ?? fmt.sampleRate
            // Datei wird beim Freigeben von `output` abgeschlossen, daher eigener Block.
            do {
                guard let output = try? AVAudioFile(forWriting: dst, settings: s, commonFormat: fmt.commonFormat, interleaved: fmt.isInterleaved)
                else { throw ConvertError.writeFailed }
                if abs(targetRate - fmt.sampleRate) > 0.5 {
                    try writeResampled(input, to: output, targetRate: targetRate)
                } else {
                    guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 32768) else { throw ConvertError.writeFailed }
                    while input.framePosition < input.length {
                        try input.read(into: buf)
                        if buf.frameLength == 0 { break }
                        try output.write(from: buf)
                    }
                }
            }
        }
        guard FileManager.default.fileExists(atPath: dst.path) else { throw ConvertError.writeFailed }
    }
}
