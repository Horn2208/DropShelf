import XCTest
import AVFoundation
import UniformTypeIdentifiers

private final class Counter: @unchecked Sendable { var n = 0 }

final class MediaTrimTests: XCTestCase {
    private var tmp: URL!
    private var cache: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        tmp = fm.temporaryDirectory.appendingPathComponent("dropshelf-trim-" + UUID().uuidString)
        cache = tmp.appendingPathComponent("cache")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tmp.appendingPathComponent("gesperrt").path)
        try? fm.removeItem(at: tmp)
    }

    private func t(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: 600) }
    private func range(_ a: Double, _ b: Double) -> CMTimeRange { CMTimeRange(start: t(a), end: t(b)) }

    func testClamp() {
        let d = t(3)
        XCTAssertEqual(MediaTrim.clamp(range: range(1, 2), duration: d).duration.seconds, 1, accuracy: 0.001)
        let neg = MediaTrim.clamp(range: range(-1, 2), duration: d)
        XCTAssertEqual(neg.start.seconds, 0); XCTAssertEqual(neg.end.seconds, 2, accuracy: 0.001)
        let over = MediaTrim.clamp(range: range(2, 9), duration: d)
        XCTAssertEqual(over.end.seconds, 3, accuracy: 0.001)
        XCTAssertEqual(MediaTrim.clamp(range: range(4, 5), duration: d).duration, .zero)
        XCTAssertEqual(MediaTrim.clamp(range: range(2, 2), duration: d).duration, .zero)
        XCTAssertEqual(MediaTrim.clamp(range: range(2, 1), duration: d).duration, .zero)
    }

    func testTrimViewRangeReplacesInvalidTimes() {
        let d = t(3)
        func r(_ a: CMTime, _ b: CMTime) -> CMTimeRange { TrimView.trimRange(reverseEnd: a, forwardEnd: b, duration: d) }
        XCTAssertEqual(r(.invalid, .invalid), CMTimeRange(start: .zero, end: d))
        XCTAssertEqual(r(t(1), .invalid), range(1, 3))
        XCTAssertEqual(r(.invalid, t(2)), range(0, 2))
        XCTAssertEqual(r(t(1), t(2)), range(1, 2))
    }

    private func tone(_ name: String) throws -> URL {
        let rate = 44100.0
        let fmt = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: rate, channels: 2, interleaved: true)!
        let n = AVAudioFrameCount(rate * 3)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n)!
        buf.frameLength = n
        let p = buf.int16ChannelData![0]
        for i in 0..<Int(n) { let v = Int16(8000 * sin(2 * .pi * 440 * Double(i) / rate)); p[2 * i] = v; p[2 * i + 1] = v }
        let u = tmp.appendingPathComponent(name)
        let f = try AVAudioFile(forWriting: u, settings: fmt.settings, commonFormat: .pcmFormatInt16, interleaved: true)
        try f.write(from: buf)
        return u
    }

    private func seconds(_ u: URL) async throws -> Double {
        try await AVURLAsset(url: u).load(.duration).seconds
    }

    func testTrimAudioCaf() async throws {
        let src = try tone("Ton.caf")
        let r = range(1, 2), c = cache!
        let out = try await withTimeout { try await MediaTrim.trim(src, range: r, cacheDir: c) }.url
        XCTAssertEqual(out.pathExtension, "m4a")
        XCTAssertTrue(out.lastPathComponent.contains("gekürzt"))
        let d = try await seconds(out)
        XCTAssertEqual(d, 1.0, accuracy: 0.05)
    }

    func testTrimEmptyRangeThrows() async throws {
        let src = try tone("Ton.caf")
        do { _ = try await MediaTrim.trim(src, range: range(5, 6), cacheDir: cache); XCTFail("sollte werfen") }
        catch MediaTrimError.emptyRange {}
    }

    func testTrimVideo() async throws {
        let src = try await makeClip()
        let r = range(0.5, 1.5), c = cache!
        let out = try await withTimeout { try await MediaTrim.trim(src, range: r, cacheDir: c) }.url
        XCTAssertEqual(out.pathExtension, "mov")
        let d = try await seconds(out)
        XCTAssertEqual(d, 1.0, accuracy: 0.15)   // Passthrough schneidet auf Keyframes/Frames (10 fps)
    }

    // MARK: Eingangsformate

    private func converted(to type: UTType) async throws -> URL {
        try await ConverterRegistry.convert(try tone("Quelle.caf"), to: type, mode: .cache,
                                            cacheDir: tmp.appendingPathComponent("quellen"))
    }

    private func trimRecordingPresets(_ src: URL) async throws -> (URL, [String]) {
        var presets: [String] = []
        let p = try await MediaTrim.trim(src, range: range(1, 2), cacheDir: cache, export: {
            presets.append($0.presetName)
            try await MediaTrim.run($0)
        })
        return (p.url, presets)
    }

    func testTrimMP3BecomesM4A() async throws {
        let src = try await converted(to: .mp3)
        XCTAssertEqual(src.pathExtension, "mp3")
        let (out, presets) = try await trimRecordingPresets(src)
        XCTAssertEqual(presets, [AVAssetExportPresetAppleM4A])
        XCTAssertEqual(out.pathExtension, "m4a")
        let d = try await seconds(out)
        XCTAssertEqual(d, 1.0, accuracy: 0.05)
    }

    func testTrimM4APassthrough() async throws {
        let src = try await converted(to: AudioConverter.m4a)
        XCTAssertEqual(src.pathExtension, "m4a")
        let (out, presets) = try await trimRecordingPresets(src)
        XCTAssertEqual(presets, [AVAssetExportPresetPassthrough])
        XCTAssertEqual(out.pathExtension, "m4a")
        let d = try await seconds(out)
        XCTAssertEqual(d, 1.0, accuracy: 0.05)
    }

    // MARK: Abbruch

    private func trimDirs() throws -> Set<String> {
        Set(try fm.contentsOfDirectory(atPath: fm.temporaryDirectory.path).filter { $0.hasPrefix("dropshelf-trim-") })
    }

    /// m4a hat zwei Presets: nach einem Abbruch darf das zweite nicht mehr laufen.
    private func assertCancelled(file: StaticString = #filePath, line: UInt = #line,
                                 _ export: @escaping @Sendable (AVAssetExportSession) async throws -> Void) async throws {
        let src = try await converted(to: AudioConverter.m4a)
        let before = try fm.contentsOfDirectory(atPath: tmp.path).sorted()
        let dirs = try trimDirs()
        let r = range(1, 2), c = cache!
        let calls = Counter()
        do {
            _ = try await withTimeout {
                try await MediaTrim.trim(src, range: r, cacheDir: c, export: { calls.n += 1; try await export($0) })
            }
            XCTFail("sollte werfen", file: file, line: line)
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)", file: file, line: line)
        }
        XCTAssertEqual(calls.n, 1, "kein weiterer Export", file: file, line: line)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: tmp.path).sorted(), before, "keine Ausgabe", file: file, line: line)
        XCTAssertFalse(fm.fileExists(atPath: c.path), "nichts im Cache", file: file, line: line)
        XCTAssertEqual(try trimDirs(), dirs, "Temp-Ordner aufgeräumt", file: file, line: line)
    }

    func testCancelDuringExport() async throws {
        try await assertCancelled { _ in
            withUnsafeCurrentTask { $0?.cancel() }
            throw MediaTrimError.exportFailed("abgebrochen")   // so meldet sich eine abgebrochene Session
        }
    }

    func testCancelBeforeExportStarts() async throws {
        try await assertCancelled {
            withUnsafeCurrentTask { $0?.cancel() }
            try await MediaTrim.run($0)
        }
    }

    func testCancelAfterExportBeforePlacing() async throws {
        try await assertCancelled {
            try await MediaTrim.run($0)
            withUnsafeCurrentTask { $0?.cancel() }
        }
    }

    // MARK: Sandbox und Ablageort

    func testSecurityScopeSpansWholeTrim() async throws {
        let src = try tone("Ton.caf")
        var log: [String] = []
        _ = try await MediaTrim.trim(src, range: range(1, 2), cacheDir: cache,
                                     startAccess: { log.append("start " + $0.lastPathComponent); return true },
                                     stopAccess: { log.append("stop " + $0.lastPathComponent) },
                                     export: { log.append("export"); try await MediaTrim.run($0) })
        XCTAssertEqual(log, ["start Ton.caf", "export", "stop Ton.caf"])

        log = []   // auch beim Fehler wird wieder freigegeben
        do {
            _ = try await MediaTrim.trim(src, range: range(5, 6), cacheDir: cache,
                                         startAccess: { _ in log.append("start"); return true },
                                         stopAccess: { _ in log.append("stop") })
            XCTFail("sollte werfen")
        } catch MediaTrimError.emptyRange {}
        XCTAssertEqual(log, ["start", "stop"])
    }

    func testCacheFallbackIsReported() async throws {
        let dir = tmp.appendingPathComponent("gesperrt")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let src = dir.appendingPathComponent("Ton.caf")
        try fm.moveItem(at: try tone("Ton.caf"), to: src)
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
        let r = range(1, 2), c = cache!
        let p = try await withTimeout { try await MediaTrim.trim(src, range: r, cacheDir: c) }
        XCTAssertTrue(p.inCache)
        XCTAssertNotNil(p.notice)
        XCTAssertEqual(p.url.deletingLastPathComponent().standardizedFileURL.path, c.standardizedFileURL.path)
    }

    /// 2-s-Clip, 64x64, 10 fps, einfarbig (alle Frames Keyframes).
    private func makeClip() async throws -> URL {
        let u = tmp.appendingPathComponent("Clip.mov")
        let w = try AVAssetWriter(outputURL: u, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64,
            AVVideoCompressionPropertiesKey: [AVVideoMaxKeyFrameIntervalKey: 1]])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64])
        w.add(input)
        XCTAssertTrue(w.startWriting())
        w.startSession(atSourceTime: .zero)
        for i in 0..<20 {
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &pb)
            let b = try XCTUnwrap(pb)
            CVPixelBufferLockBaseAddress(b, [])
            memset(CVPixelBufferGetBaseAddress(b), 0x80, CVPixelBufferGetBytesPerRow(b) * 64)
            CVPixelBufferUnlockBaseAddress(b, [])
            try await waitReady(input)
            adaptor.append(b, withPresentationTime: CMTime(value: Int64(i), timescale: 10))
        }
        input.markAsFinished()
        await w.finishWriting()
        XCTAssertEqual(w.status, .completed, "\(String(describing: w.error))")
        return u
    }
}
