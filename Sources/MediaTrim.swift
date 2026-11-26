import AVFoundation

enum MediaTrimError: LocalizedError {
    case emptyRange, exportFailed(String)
    var errorDescription: String? {
        switch self {
        case .emptyRange: return "Der gewählte Bereich ist leer."
        case .exportFailed(let r): return "Das Kürzen ist fehlgeschlagen: \(r)"
        }
    }
}

/// Schneidet Audio/Video auf einen Zeitbereich (PLAN 14.4). Audio-Ziel ist immer .m4a (kein MP3-Encoder, E4).
enum MediaTrim {
    /// Begrenzt `range` auf 0…duration; leer oder außerhalb → Dauer 0.
    static func clamp(range: CMTimeRange, duration: CMTime) -> CMTimeRange {
        guard range.start.isNumeric, range.end.isNumeric, duration.isNumeric else { return CMTimeRange(start: .zero, duration: .zero) }
        let start = max(range.start, .zero)
        let end = min(range.end, duration)
        guard end > start else { return CMTimeRange(start: .zero, duration: .zero) }
        return CMTimeRange(start: start, end: end)
    }

    @discardableResult
    static func trim(_ url: URL, range: CMTimeRange, mode: OutputMode = .besideOriginal,
                     cacheDir: URL = Shelf.cacheDir,
                     startAccess: (URL) -> Bool = { $0.startAccessingSecurityScopedResource() },
                     stopAccess: (URL) -> Void = { $0.stopAccessingSecurityScopedResource() },
                     export: (AVAssetExportSession) async throws -> Void = { try await MediaTrim.run($0) }
    ) async throws -> FileOutput.Placement {
        let started = startAccess(url)
        defer { if started { stopAccess(url) } }

        let asset = AVURLAsset(url: url)
        let r = clamp(range: range, duration: try await asset.load(.duration))
        guard r.duration > .zero else { throw MediaTrimError.emptyRange }

        let isVideo = !(try await asset.loadTracks(withMediaType: .video)).isEmpty
        let type: AVFileType
        let presets: [String]
        if isVideo {
            type = url.pathExtension.lowercased() == "mov" ? .mov : .mp4
            presets = [AVAssetExportPresetPassthrough, AVAssetExportPresetHighestQuality]
        } else {
            type = .m4a
            // Passthrough nur, wenn die Quelle schon AAC/m4a ist; sonst (MP3, wav, caf …) neu kodieren.
            presets = url.pathExtension.lowercased() == "m4a"
                ? [AVAssetExportPresetPassthrough, AVAssetExportPresetAppleM4A] : [AVAssetExportPresetAppleM4A]
        }
        let ext = type == .mov ? "mov" : (type == .mp4 ? "mp4" : "m4a")

        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("dropshelf-trim-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let out = tmpDir.appendingPathComponent("out." + ext)

        var lastError = "kein passendes Export-Preset"
        for (i, preset) in presets.enumerated() {
            guard await AVAssetExportSession.compatibility(ofExportPreset: preset, with: asset, outputFileType: type),
                  let session = AVAssetExportSession(asset: asset, presetName: preset),
                  session.supportedFileTypes.contains(type) else {
                if i == 0 && preset == AVAssetExportPresetPassthrough { print("MediaTrim: Passthrough nicht möglich für \(url.lastPathComponent), Rückfall") }
                continue
            }
            session.outputURL = out
            session.outputFileType = type
            session.timeRange = r
            do {
                try await export(session)
                try Task.checkCancellation()
                return try FileOutput.placeReporting(out, for: url, suffix: "gekürzt", ext: ext, mode: mode, cacheDir: cacheDir)
            } catch let e as FileOutputError { throw e } catch {
                try Task.checkCancellation()   // Abbruch ist kein Preset-Fehler: kein Rückfall
                lastError = error.localizedDescription
                print("MediaTrim: Preset \(preset) fehlgeschlagen (\(lastError))")
                try? FileManager.default.removeItem(at: out)
            }
        }
        try Task.checkCancellation()
        throw MediaTrimError.exportFailed(lastError)
    }

    /// Start und Abbruch unter einem Lock: `exportAsynchronously` nach `cancelExport` auf einer noch nicht
    /// gestarteten Session wirft eine NSException (Absturz).
    private final class Box: @unchecked Sendable {
        let s: AVAssetExportSession
        private let lock = NSLock()
        private var started = false, cancelled = false
        init(_ s: AVAssetExportSession) { self.s = s }

        /// false: schon abgebrochen, nichts gestartet.
        func start(_ done: @escaping @Sendable () -> Void) -> Bool {
            lock.withLock {
                guard !cancelled else { return false }
                started = true
                s.exportAsynchronously(completionHandler: done)
                return true
            }
        }
        func cancel() {
            lock.withLock {
                cancelled = true
                if started { s.cancelExport() }
            }
        }
    }

    // exportAsynchronously statt export(to:as:), weil das Deployment-Target macOS 14 ist (die async API braucht 15).
    static func run(_ session: AVAssetExportSession) async throws {
        let box = Box(session)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                let started = box.start {
                    if box.s.status == .completed { c.resume() }
                    else { c.resume(throwing: box.s.error ?? MediaTrimError.exportFailed("Status \(box.s.status.rawValue)")) }
                }
                if !started { c.resume(throwing: CancellationError()) }
            }
        } onCancel: { box.cancel() }
    }
}
