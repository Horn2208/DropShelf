import XCTest
import AVFoundation
import UniformTypeIdentifiers

final class AudioConverterTests: XCTestCase {
    private var tmp: URL!
    private var cache: URL!
    private let fm = FileManager.default
    private let secs = 1.5

    override func setUpWithError() throws {
        tmp = fm.temporaryDirectory.appendingPathComponent("dropshelf-audconv-" + UUID().uuidString)
        cache = tmp.appendingPathComponent("cache")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? fm.removeItem(at: tmp) }

    private func tone(_ name: String = "Ton.wav") throws -> URL {
        let rate = 44100.0
        let fmt = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: rate, channels: 2, interleaved: true)!
        let n = AVAudioFrameCount(rate * secs)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n)!
        buf.frameLength = n
        let p = buf.int16ChannelData![0]
        for i in 0..<Int(n) {
            let v = Int16(8000 * sin(2 * .pi * 440 * Double(i) / rate))
            p[2 * i] = v; p[2 * i + 1] = v
        }
        let u = tmp.appendingPathComponent(name)
        let f = try AVAudioFile(forWriting: u, settings: fmt.settings, commonFormat: .pcmFormatInt16, interleaved: true)
        try f.write(from: buf)
        return u
    }

    private func duration(_ u: URL) throws -> Double {
        let f = try AVAudioFile(forReading: u)
        return Double(f.length) / f.processingFormat.sampleRate
    }

    func testTargetsForMP3() {
        let t = ConverterRegistry.targets(for: .mp3)
        XCTAssertFalse(t.contains(.mp3)) // gleiches Format nie als Ziel
        XCTAssertTrue(t.contains(AudioConverter.m4a))
        XCTAssertTrue(t.contains(.wav))
        XCTAssertTrue(AudioConverter.writable.contains(.mp3))
        XCTAssertTrue(ConverterRegistry.targets(for: .wav).contains(.mp3))
    }

    func testMp3RoundTrip() async throws {
        let wav = try tone()
        let mp3 = try await ConverterRegistry.convert(wav, to: .mp3, mode: .cache, cacheDir: cache)
        XCTAssertEqual(mp3.pathExtension, "mp3")
        let bytes = try Data(contentsOf: mp3)
        XCTAssertGreaterThan(bytes.count, 100)
        // Gültiger MP3-Kopf: ID3-Tag oder MPEG-Frame-Sync (0xFF 0xE0)
        let isID3 = bytes.prefix(3) == Data("ID3".utf8)
        let isSync = bytes[0] == 0xFF && (bytes[1] & 0xE0) == 0xE0
        XCTAssertTrue(isID3 || isSync)
        XCTAssertEqual(try duration(mp3), secs, accuracy: 0.05)
        let back = try await ConverterRegistry.convert(mp3, to: .wav, mode: .cache, cacheDir: cache)
        XCTAssertEqual(try duration(back), secs, accuracy: 0.05)
    }

    func testRoundTripWavM4aCafWav() async throws {
        let wav = try tone()
        XCTAssertEqual(try duration(wav), secs, accuracy: 0.05)
        let m4a = try await ConverterRegistry.convert(wav, to: AudioConverter.m4a, mode: .cache, cacheDir: cache)
        XCTAssertEqual(m4a.pathExtension, "m4a")
        XCTAssertEqual(try duration(m4a), secs, accuracy: 0.05)
        let caf = try await ConverterRegistry.convert(m4a, to: AudioConverter.caf, mode: .cache, cacheDir: cache)
        XCTAssertEqual(try duration(caf), secs, accuracy: 0.05)
        let back = try await ConverterRegistry.convert(caf, to: .wav, mode: .cache, cacheDir: cache)
        XCTAssertEqual(try duration(back), secs, accuracy: 0.05)
    }

    func testPresetsAndAiff() async throws {
        let wav = try tone()
        var o = ConvertOptions(); o.preset = "alac"
        let alac = try await ConverterRegistry.convert(wav, to: AudioConverter.m4a, o, mode: .cache, cacheDir: cache)
        XCTAssertEqual(try AVAudioFile(forReading: alac).fileFormat.settings[AVFormatIDKey] as? UInt32, kAudioFormatAppleLossless)
        XCTAssertEqual(try duration(alac), secs, accuracy: 0.05)
        let aac = try await ConverterRegistry.convert(wav, to: AudioConverter.m4a, mode: .cache, cacheDir: cache)
        XCTAssertEqual(try AVAudioFile(forReading: aac).fileFormat.settings[AVFormatIDKey] as? UInt32, kAudioFormatMPEG4AAC)
        let aiff = try await ConverterRegistry.convert(wav, to: .aiff, mode: .cache, cacheDir: cache)
        XCTAssertEqual(try duration(aiff), secs, accuracy: 0.05)
    }

    func testFlacAlwaysWritableAndRoundTrip() async throws {
        XCTAssertTrue(AudioConverter.writable.contains(AudioConverter.flac))
        XCTAssertTrue(ConverterRegistry.targets(for: .wav).contains(AudioConverter.flac))
        let flac = try await ConverterRegistry.convert(try tone(), to: AudioConverter.flac, mode: .cache, cacheDir: cache)
        XCTAssertEqual(flac.pathExtension, "flac")
        let head = try Data(contentsOf: flac).prefix(4)
        XCTAssertEqual(head, Data("fLaC".utf8))
        XCTAssertEqual(try duration(flac), secs, accuracy: 0.05)
        let back = try await ConverterRegistry.convert(flac, to: .wav, mode: .cache, cacheDir: cache)
        XCTAssertEqual(try duration(back), secs, accuracy: 0.05)
    }

    func testOggVorbisRoundTrip() async throws {
        XCTAssertTrue(AudioConverter.writable.contains(AudioConverter.ogg))
        XCTAssertTrue(ConverterRegistry.targets(for: .wav).contains(AudioConverter.ogg))
        let ogg = try await ConverterRegistry.convert(try tone(), to: AudioConverter.ogg, mode: .cache, cacheDir: cache)
        XCTAssertEqual(ogg.pathExtension, "ogg")
        let bytes = try Data(contentsOf: ogg)
        XCTAssertEqual(bytes.prefix(4), Data("OggS".utf8))
        let back = try await ConverterRegistry.convert(ogg, to: .wav, mode: .cache, cacheDir: cache)
        XCTAssertEqual(try duration(back), secs, accuracy: 0.05)
    }

    func testOggOpusRoundTrip() async throws {
        var o = ConvertOptions(); o.preset = "opus"
        let opus = try await ConverterRegistry.convert(try tone(), to: AudioConverter.ogg, o, mode: .cache, cacheDir: cache)
        XCTAssertEqual(opus.pathExtension, "ogg")
        let bytes = try Data(contentsOf: opus)
        XCTAssertEqual(bytes.prefix(4), Data("OggS".utf8))
        XCTAssertNotNil(bytes.range(of: Data("OpusHead".utf8)))
        let back = try await ConverterRegistry.convert(opus, to: .wav, mode: .cache, cacheDir: cache)
        XCTAssertEqual(try duration(back), secs, accuracy: 0.05)
    }

    func testWavPackRoundTrip() async throws {
        XCTAssertTrue(AudioConverter.writable.contains(AudioConverter.wavpack))
        XCTAssertTrue(ConverterRegistry.targets(for: .wav).contains(AudioConverter.wavpack))
        let wv = try await ConverterRegistry.convert(try tone(), to: AudioConverter.wavpack, mode: .cache, cacheDir: cache)
        XCTAssertEqual(wv.pathExtension, "wv")
        let bytes = try Data(contentsOf: wv)
        XCTAssertEqual(bytes.prefix(4), Data("wvpk".utf8))
        let back = try await ConverterRegistry.convert(wv, to: .wav, mode: .cache, cacheDir: cache)
        XCTAssertEqual(try duration(back), secs, accuracy: 0.05)
    }

    func testM4aHEAACRoundTrip() async throws {
        try XCTSkipUnless(AudioConverter.supportsHEAAC, "HE-AAC-Encoder auf diesem Mac nicht verfügbar")
        XCTAssertTrue(AudioConverter.availablePresets(for: AudioConverter.m4a).contains("heaac"))
        let wav = try tone()
        var o = ConvertOptions(); o.preset = "heaac"
        let heaac = try await ConverterRegistry.convert(wav, to: AudioConverter.m4a, o, mode: .cache, cacheDir: cache)
        XCTAssertEqual(heaac.pathExtension, "m4a")
        let fmtID = try AVAudioFile(forReading: heaac).fileFormat.settings[AVFormatIDKey] as? UInt32
        XCTAssertEqual(fmtID, kAudioFormatMPEG4AAC_HE)
        XCTAssertEqual(try duration(heaac), secs, accuracy: 0.05)
        let back = try await ConverterRegistry.convert(heaac, to: .wav, mode: .cache, cacheDir: cache)
        XCTAssertEqual(try duration(back), secs, accuracy: 0.05)
    }

    func testCafOpusRoundTrip() async throws {
        try XCTSkipUnless(AudioConverter.supportsCAFOpus, "Opus-Encoder auf diesem Mac nicht verfügbar")
        XCTAssertTrue(AudioConverter.availablePresets(for: AudioConverter.caf).contains("opus"))
        let wav = try tone()
        var o = ConvertOptions(); o.preset = "opus"
        let caf = try await ConverterRegistry.convert(wav, to: AudioConverter.caf, o, mode: .cache, cacheDir: cache)
        XCTAssertEqual(caf.pathExtension, "caf")
        let fmtID = try AVAudioFile(forReading: caf).fileFormat.settings[AVFormatIDKey] as? UInt32
        XCTAssertEqual(fmtID, kAudioFormatOpus)
        XCTAssertEqual(try duration(caf), secs, accuracy: 0.05)
        let back = try await ConverterRegistry.convert(caf, to: .wav, mode: .cache, cacheDir: cache)
        XCTAssertEqual(try duration(back), secs, accuracy: 0.05)
    }

    func testOpusExtensionInput() async throws {
        var o = ConvertOptions(); o.preset = "opus"
        let ogg = try await ConverterRegistry.convert(try tone(), to: AudioConverter.ogg, o, mode: .cache, cacheDir: cache)
        let opusURL = tmp.appendingPathComponent("Ton.opus")
        try fm.copyItem(at: ogg, to: opusURL)
        let wav = try await ConverterRegistry.convert(opusURL, to: .wav, mode: .cache, cacheDir: cache)
        XCTAssertEqual(try duration(wav), secs, accuracy: 0.05)
    }
}
