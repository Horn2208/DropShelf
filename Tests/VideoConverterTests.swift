import XCTest
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

final class VideoConverterTests: XCTestCase {
    private var tmp: URL!
    private var cache: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        tmp = fm.temporaryDirectory.appendingPathComponent("dropshelf-vidconv-" + UUID().uuidString)
        cache = tmp.appendingPathComponent("cache")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? fm.removeItem(at: tmp) }

    /// 2 s, 5 fps, 64x64, einfarbig; mit Tonspur (Stille-LPCM→AAC) nicht nötig: nur Video, Ton separat unten.
    private func clip(_ name: String, type: AVFileType, audio: Bool = true) async throws -> URL {
        let u = tmp.appendingPathComponent(name)
        let w = try AVAssetWriter(outputURL: u, fileType: type)
        let vin = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64])
        let ad = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vin, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 64,
            kCVPixelBufferHeightKey as String: 64])
        w.add(vin)
        var ain: AVAssetWriterInput?
        if audio {
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1])
            w.add(a); ain = a
        }
        XCTAssertTrue(w.startWriting())
        w.startSession(atSourceTime: .zero)
        if let ain {
            // 2 s Stille als LPCM-Sample-Buffer. Ton ZUERST anhängen und abschließen: Bei zwei Eingängen
            // interleavt AVAssetWriter und meldet für Video sonst ggf. nie wieder isReadyForMoreMediaData
            // (wartet auf Ton, der erst nach der Video-Schleife käme) -> Endlosschleife im Gesamtlauf.
            let frames = 88200
            var asbd = AudioStreamBasicDescription(mSampleRate: 44100, mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, mBytesPerPacket: 2,
                mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
            var fd: CMAudioFormatDescription?
            CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                           magicCookie: nil, extensions: nil, formatDescriptionOut: &fd)
            var bb: CMBlockBuffer?
            CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: frames * 2, blockAllocator: nil,
                customBlockSource: nil, offsetToData: 0, dataLength: frames * 2, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &bb)
            CMBlockBufferFillDataBytes(with: 0, blockBuffer: bb!, offsetIntoDestination: 0, dataLength: frames * 2)
            var sb: CMSampleBuffer?
            CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: bb!, formatDescription: fd!,
                sampleCount: frames, presentationTimeStamp: .zero, packetDescriptions: nil, sampleBufferOut: &sb)
            try await waitReady(ain)
            XCTAssertTrue(ain.append(sb!))
            ain.markAsFinished()
        }
        for i in 0..<10 {
            try await waitReady(vin)
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, ad.pixelBufferPool!, &pb)
            CVPixelBufferLockBaseAddress(pb!, [])
            memset(CVPixelBufferGetBaseAddress(pb!), i % 2 == 0 ? 0x30 : 0xC0, CVPixelBufferGetDataSize(pb!))
            CVPixelBufferUnlockBaseAddress(pb!, [])
            XCTAssertTrue(ad.append(pb!, withPresentationTime: CMTime(value: Int64(i), timescale: 5)))
        }
        vin.markAsFinished()
        await w.finishWriting()
        XCTAssertEqual(w.status, .completed, "\(String(describing: w.error))")
        return u
    }

    private func duration(_ u: URL) async throws -> Double { try await AVURLAsset(url: u).load(.duration).seconds }

    /// Die Frist greift auch, wenn die Arbeit nicht auf Abbruch reagiert (Continuation wie bei exportAsynchronously).
    func testWithTimeoutReturnsForNonCancellableWork() async {
        let start = Date()
        do { _ = try await withTimeout(0.2) {
                await withCheckedContinuation { c in DispatchQueue.global().asyncAfter(deadline: .now() + 2) { c.resume() } }
                return 1
            }; XCTFail("kein Timeout") }
        catch { XCTAssertTrue(error is TestTimeout) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
    }

    func testTargets() {
        let t = ConverterRegistry.targets(for: .mpeg4Movie)
        XCTAssertTrue(t.contains(.quickTimeMovie)); XCTAssertTrue(t.contains(.gif))
        XCTAssertTrue(t.contains(AudioConverter.m4a)); XCTAssertTrue(t.contains(.wav))
        XCTAssertFalse(t.contains(.mpeg4Movie))
        XCTAssertTrue(ConverterRegistry.targets(for: VideoConverter.m4v).contains(.mpeg4Movie))
    }

    func testGIFPresetParsing() {
        XCTAssertEqual(VideoConverter.parseGIFPreset(nil).fps, 10)
        let p = VideoConverter.parseGIFPreset("fps:5,width:200")
        XCTAssertEqual(p.fps, 5); XCTAssertEqual(p.width, 200)
    }

    func testMovToMp4Passthrough() async throws {
        let mov = try await clip("a.mov", type: .mov)
        let reenc = await VideoConverter.willReencode(mov, to: .mpeg4Movie)
        XCTAssertFalse(reenc)
        let c = cache!
        try await withTimeout {
            let out = try await ConverterRegistry.convert(mov, to: .mpeg4Movie, mode: .cache, cacheDir: c)
            XCTAssertEqual(out.pathExtension, "mp4")
            let d = try await AVURLAsset(url: out).load(.duration).seconds
            XCTAssertEqual(d, 2, accuracy: 0.6)
        }
    }

    func testMp4ToM4aAndWav() async throws {
        let mp4 = try await clip("b.mp4", type: .mp4)
        let c = cache!
        try await withTimeout {
            let m4a = try await ConverterRegistry.convert(mp4, to: AudioConverter.m4a, mode: .cache, cacheDir: c)
            XCTAssertEqual(m4a.pathExtension, "m4a")
            let d = try await AVURLAsset(url: m4a).load(.duration).seconds
            XCTAssertEqual(d, 2, accuracy: 0.6)
            let wav = try await ConverterRegistry.convert(mp4, to: .wav, mode: .cache, cacheDir: c)
            let f = try AVAudioFile(forReading: wav)
            XCTAssertEqual(Double(f.length) / f.processingFormat.sampleRate, 2, accuracy: 0.6)
        }
    }

    func testMp4ToGifHasSeveralFrames() async throws {
        let mp4 = try await clip("c.mp4", type: .mp4, audio: false)
        let c = cache!
        try await withTimeout {
            var o = ConvertOptions(); o.preset = "fps:5,width:32"
            let gif = try await ConverterRegistry.convert(mp4, to: .gif, o, mode: .cache, cacheDir: c)
            let src = CGImageSourceCreateWithURL(gif as CFURL, nil)!
            XCTAssertGreaterThan(CGImageSourceGetCount(src), 1)
            let img = CGImageSourceCreateImageAtIndex(src, 0, nil)!
            XCTAssertLessThanOrEqual(img.width, 32)
        }
    }

    func testMp4ToMovProRes422() async throws {
        try XCTSkipUnless(VideoConverter.supportsProRes422, "ProRes 422 auf diesem Mac nicht verfügbar")
        XCTAssertTrue(VideoConverter.availablePresets(for: .quickTimeMovie).contains("prores422"))
        let mp4 = try await clip("d.mp4", type: .mp4)
        let reenc = await VideoConverter.willReencode(mp4, to: .quickTimeMovie, preset: "prores422")
        XCTAssertTrue(reenc)
        let c = cache!
        try await withTimeout {
            var o = ConvertOptions(); o.preset = "prores422"
            let mov = try await ConverterRegistry.convert(mp4, to: .quickTimeMovie, o, mode: .cache, cacheDir: c)
            XCTAssertEqual(mov.pathExtension, "mov")
            let asset = AVURLAsset(url: mov)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            let vTrack = try XCTUnwrap(tracks.first)
            let fds = try await vTrack.load(.formatDescriptions)
            let fd = try XCTUnwrap(fds.first)
            let subType = CMFormatDescriptionGetMediaSubType(fd)
            XCTAssertEqual(subType, kCMVideoCodecType_AppleProRes422)
            let d = try await asset.load(.duration).seconds
            XCTAssertEqual(d, 2, accuracy: 0.6)
        }
    }

    func testUnsupportedContainerGivesGermanError() async throws {
        let mkv = tmp.appendingPathComponent("clip.mkv")
        try Data([0x1A, 0x45, 0xDF, 0xA3, 0x00, 0x00]).write(to: mkv)
        let c = cache!
        do {
            _ = try await ConverterRegistry.convert(mkv, to: .mpeg4Movie, mode: .cache, cacheDir: c)
            XCTFail("Ungültiges/nicht unterstütztes MKV sollte fehlschlagen")
        } catch let err as ConvertError {
            let desc = err.localizedDescription
            XCTAssertTrue(desc.contains("AVFoundation") || desc.contains("MKV"), desc)
        }
    }
}

/// Fehler, wenn ein Medien-Test seine Frist überschreitet.
struct TestTimeout: Error {}

/// Setzt eine Continuation genau einmal fort (wer zuerst kommt: Ergebnis oder Frist).
private final class Once<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock(); private var c: CheckedContinuation<T, Error>?
    init(_ c: CheckedContinuation<T, Error>) { self.c = c }
    func resume(_ r: Result<T, Error>) { lock.lock(); let x = c; c = nil; lock.unlock(); x?.resume(with: r) }
}

/// Führt `op` mit Frist aus und kehrt spätestens nach `seconds` zurück, auch wenn `op` nicht auf Abbruch reagiert
/// (bewusst kein TaskGroup: die wartet beim Verlassen auf alle Kinder). `op` wird bei Fristablauf abgebrochen.
func withTimeout<T: Sendable>(_ seconds: Double = 60, _ op: @escaping @Sendable () async throws -> T) async throws -> T {
    let work = Task { try await op() }
    return try await withCheckedThrowingContinuation { c in
        let once = Once(c)
        let timer = Task {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
            work.cancel(); once.resume(.failure(TestTimeout()))
        }
        Task { let r = await work.result; timer.cancel(); once.resume(r) }
    }
}

/// Wartet (max. ~10 s) bis der Writer-Eingang Daten annimmt; wirft statt endlos zu pollen.
func waitReady(_ input: AVAssetWriterInput) async throws {
    for _ in 0..<5000 {
        if input.isReadyForMoreMediaData { return }
        try await Task.sleep(nanoseconds: 2_000_000)
    }
    throw TestTimeout()
}
