import Foundation
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// Video-Konverter: Container (mov/mp4/m4v, plus avi/mkv/webm falls AVFoundation sie öffnet), Ton (m4a/wav) und GIF.
/// Container: Passthrough, wenn die Spuren in den Zielcontainer passen, sonst neu kodiert (`willReencode` vorab fragen,
/// damit die UI „wird neu kodiert“ anzeigen kann).
/// Ziel mov: `ConvertOptions.preset` = "prores422" (Apple ProRes 422 + LPCM, nur wenn kompatibel; wird immer neu kodiert).
/// GIF: `ConvertOptions.preset` = "fps:10,width:480" (beide optional).
/// Warnung: GIFs werden schnell riesig (Frames × Breite²); deshalb höchstens `maxGIFFrames` Frames, bei langen Clips sinkt die Bildrate.
enum VideoConverter {
    static let m4v = UTType("com.apple.m4v-video") ?? UTType(filenameExtension: "m4v")!
    static let mkv = UTType("org.matroska.mkv") ?? UTType(filenameExtension: "mkv")!
    static let webm = UTType("org.webmproject.webm") ?? UTType(filenameExtension: "webm")!
    static let maxGIFFrames = 300
    static let defaultFPS = 10.0
    static let defaultGIFWidth = 480.0

    /// Zusätzliche Container (mkv/webm/avi) werden nur als lesbar gemeldet, wenn AVFoundation sie kennt.
    static var readable: [UTType] {
        var list: [UTType] = [.quickTimeMovie, .mpeg4Movie, m4v]
        let avTypes = Set(AVURLAsset.audiovisualTypes().map(\.rawValue))
        for t in [mkv, webm, UTType.avi] where avTypes.contains(t.identifier) && !list.contains(t) {
            list.append(t)
        }
        return list
    }

    /// Endungen bekannter Container (mkv/webm/avi), die AVFoundation auf diesem Mac nicht öffnet.
    static var knownUnsupportedContainerExtensions: Set<String> {
        let supported = Set(readable.compactMap { $0.preferredFilenameExtension?.lowercased() })
        return Set(["mkv", "webm", "avi"]).subtracting(supported)
    }

    static var supportsProRes422: Bool {
        AVAssetExportSession.allExportPresets().contains(AVAssetExportPresetAppleProRes422LPCM)
    }

    static func availablePresets(for target: UTType) -> [String] {
        target == .quickTimeMovie ? (["default"] + (supportsProRes422 ? ["prores422"] : [])) : []
    }

    static var converter: Converter {
        var pairs = Set<Conversion>()
        for f in readable {
            for t in [UTType.quickTimeMovie, .mpeg4Movie] where t != f { pairs.insert(Conversion(from: f, to: t)) }
            for t in [AudioConverter.m4a, .wav, .gif] { pairs.insert(Conversion(from: f, to: t)) }
        }
        return Converter(id: "video", pairs: pairs) { src, dst, o in
            let started = src.startAccessingSecurityScopedResource()
            defer { if started { src.stopAccessingSecurityScopedResource() } }
            guard let to = UTType(filenameExtension: dst.pathExtension) else { throw ConvertError.unsupported }
            let asset = AVURLAsset(url: src)
            let ext = src.pathExtension.lowercased()
            if ["mkv", "webm", "avi"].contains(ext) {
                let readableAsset = (try? await asset.load(.isReadable)) ?? false
                let tracks = (try? await asset.load(.tracks)) ?? []
                guard readableAsset, !tracks.isEmpty else {
                    throw ConvertError.unsupportedContainer(ext.uppercased())
                }
            }
            switch to {
            case .quickTimeMovie, .mpeg4Movie: try await exportContainer(asset, dst, to, preset: o.preset)
            case AudioConverter.m4a: try await export(asset, AVAssetExportPresetAppleM4A, .m4a, dst)
            case .wav: try await writeWAV(asset, dst)
            case .gif: try await writeGIF(asset, dst, o.preset)
            default: throw ConvertError.unsupported
            }
        }
    }

    /// true, wenn neu kodiert werden muss (Passthrough nicht möglich oder ProRes-422-Preset gewählt).
    static func willReencode(_ src: URL, to: UTType, preset: String? = nil) async -> Bool {
        guard let ft = fileType(to) else { return false }
        if to == .quickTimeMovie, preset?.lowercased() == "prores422" { return true }
        return await !AVAssetExportSession.compatibility(ofExportPreset: AVAssetExportPresetPassthrough,
                                                         with: AVURLAsset(url: src), outputFileType: ft)
    }

    private static func fileType(_ t: UTType) -> AVFileType? {
        t == .quickTimeMovie ? .mov : t == .mpeg4Movie ? .mp4 : nil
    }

    private static func exportContainer(_ asset: AVURLAsset, _ dst: URL, _ to: UTType, preset: String?) async throws {
        guard let ft = fileType(to) else { throw ConvertError.unsupported }
        if to == .quickTimeMovie, preset?.lowercased() == "prores422" {
            guard supportsProRes422,
                  await AVAssetExportSession.compatibility(ofExportPreset: AVAssetExportPresetAppleProRes422LPCM,
                                                           with: asset, outputFileType: .mov)
            else { throw ConvertError.unsupported }
            try await export(asset, AVAssetExportPresetAppleProRes422LPCM, .mov, dst)
            return
        }
        if await AVAssetExportSession.compatibility(ofExportPreset: AVAssetExportPresetPassthrough, with: asset, outputFileType: ft) {
            try await export(asset, AVAssetExportPresetPassthrough, ft, dst)
        } else {
            let hevc = await AVAssetExportSession.compatibility(ofExportPreset: AVAssetExportPresetHEVCHighestQuality, with: asset, outputFileType: ft)
            try await export(asset, hevc ? AVAssetExportPresetHEVCHighestQuality : AVAssetExportPresetHighestQuality, ft, dst)
        }
    }

    private static func export(_ asset: AVAsset, _ preset: String, _ ft: AVFileType, _ dst: URL) async throws {
        guard let s = AVAssetExportSession(asset: asset, presetName: preset) else { throw ConvertError.unreadable }
        s.outputURL = dst
        s.outputFileType = ft
        nonisolated(unsafe) let session = s
        // Abbruch des Tasks bricht den Export ab (sonst wartet die Continuation unabbrechbar).
        await withTaskCancellationHandler {
            await withCheckedContinuation { c in session.exportAsynchronously { c.resume() } }
        } onCancel: { session.cancelExport() }
        guard session.status == .completed else { throw ConvertError.writeFailed }
    }

    private static func writeWAV(_ asset: AVAsset, _ dst: URL) async throws {
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw ConvertError.unreadable }
        guard let fd = try await track.load(.formatDescriptions).first,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee else { throw ConvertError.unreadable }
        let pcm: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16,
                                  AVSampleRateKey: asbd.mSampleRate, AVNumberOfChannelsKey: Int(asbd.mChannelsPerFrame),
                                  AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                                  AVLinearPCMIsNonInterleaved: false]
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: pcm)
        guard reader.canAdd(out) else { throw ConvertError.unreadable }
        reader.add(out)
        let writer = try AVAssetWriter(outputURL: dst, fileType: .wav)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: pcm)
        guard writer.canAdd(input) else { throw ConvertError.writeFailed }
        writer.add(input)
        guard reader.startReading(), writer.startWriting() else { throw ConvertError.writeFailed }
        writer.startSession(atSourceTime: .zero)
        // ponytail: Polling statt requestMediaDataWhenReady; reicht für Dateikonvertierung.
        while let buf = out.copyNextSampleBuffer() {
            while !input.isReadyForMoreMediaData {
                if writer.status == .failed { throw ConvertError.writeFailed }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            guard input.append(buf) else { throw ConvertError.writeFailed }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed, reader.status != .failed else { throw ConvertError.writeFailed }
    }

    static func parseGIFPreset(_ p: String?) -> (fps: Double, width: Double) {
        var fps = defaultFPS, width = defaultGIFWidth
        for part in (p ?? "").split(separator: ",") {
            let kv = part.split(separator: ":").map { $0.trimmingCharacters(in: .whitespaces) }
            guard kv.count == 2, let v = Double(kv[1]), v > 0 else { continue }
            if kv[0] == "fps" { fps = min(v, 30) } else if kv[0] == "width" { width = min(v, 2000) }
        }
        return (fps, width)
    }

    private static func writeGIF(_ asset: AVAsset, _ dst: URL, _ preset: String?) async throws {
        guard try await !asset.loadTracks(withMediaType: .video).isEmpty else { throw ConvertError.unreadable }
        let secs = try await asset.load(.duration).seconds
        guard secs.isFinite, secs > 0 else { throw ConvertError.unreadable }
        var (fps, width) = parseGIFPreset(preset)
        fps = min(fps, Double(maxGIFFrames) / secs)  // Obergrenze Frames
        let count = max(1, min(maxGIFFrames, Int((secs * fps).rounded(.down))))
        let step = secs / Double(count)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: width, height: 100_000)
        gen.requestedTimeToleranceBefore = .positiveInfinity
        gen.requestedTimeToleranceAfter = .positiveInfinity
        guard let d = CGImageDestinationCreateWithURL(dst as CFURL, UTType.gif.identifier as CFString, count, nil) else { throw ConvertError.writeFailed }
        CGImageDestinationSetProperties(d, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: step]] as CFDictionary
        let times = (0..<count).map { CMTime(seconds: (Double($0) + 0.5) * step, preferredTimescale: 600) }
        for await r in gen.images(for: times) {
            guard let img = try? r.image else { throw ConvertError.unreadable }
            CGImageDestinationAddImage(d, img, frameProps)
        }
        guard CGImageDestinationFinalize(d) else { throw ConvertError.writeFailed }
    }
}
