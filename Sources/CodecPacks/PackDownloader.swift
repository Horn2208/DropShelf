import Foundation
import CryptoKit

enum PackError: LocalizedError {
    case hashMismatch, network, diskFull, alreadyRunning
    var errorDescription: String? {
        switch self {
        case .hashMismatch: return "Der Download ist beschädigt (Prüfsumme stimmt nicht) und wurde verworfen."
        case .network: return "Der Codec konnte nicht heruntergeladen werden. Bitte Netzwerk prüfen."
        case .diskFull: return "Nicht genug Speicherplatz für den Codec."
        case .alreadyRunning: return "Dieser Codec wird bereits geladen."
        }
    }
}

/// Lädt ein Paket, prüft SHA-256 und legt es atomar unter `<root>/<id>/<version>/<id>.dylib` ab.
actor PackDownloader {
    /// Liefert eine temporäre Datei, die dem Aufrufer gehört.
    typealias Fetch = @Sendable (URL, @escaping @Sendable (Double) -> Void) async throws -> URL

    static let shared = PackDownloader()
    static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DropShelf/Codecs")
    }

    private let root: URL
    private let fetch: Fetch
    private var running = Set<String>()

    init(root: URL = PackDownloader.defaultRoot, fetch: @escaping Fetch = PackDownloader.sessionFetch) {
        self.root = root
        self.fetch = fetch
    }

    func install(_ pack: Pack, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        guard running.insert(pack.id).inserted else { throw PackError.alreadyRunning }
        defer { running.remove(pack.id) }
        let fm = FileManager.default
        let tmp: URL
        do { tmp = try await fetch(pack.url, progress) } catch { throw Self.map(error) }
        defer { try? fm.removeItem(at: tmp) }
        guard try Self.sha256(tmp) == pack.sha256.lowercased() else { throw PackError.hashMismatch }
        let packDir = root.appendingPathComponent(pack.id)
        let dir = packDir.appendingPathComponent(pack.version)
        let dest = dir.appendingPathComponent(pack.id + ".dylib")
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let staged = dir.appendingPathComponent(".part")  // gleicher Ordner: der letzte Schritt ist ein atomares Umbenennen
            try? fm.removeItem(at: staged)
            try fm.moveItem(at: tmp, to: staged)
            try? fm.removeItem(at: dest)
            try fm.moveItem(at: staged, to: dest)
            // Alte Versionen erst jetzt, nach erfolgreicher Prüfung und Ablage.
            for old in (try? fm.contentsOfDirectory(atPath: packDir.path)) ?? [] where old != pack.version {
                try? fm.removeItem(at: packDir.appendingPathComponent(old))
            }
        } catch { throw Self.map(error) }
        return dest
    }

    private static func sha256(_ url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func map(_ error: Error) -> Error {
        if error is PackError || error is CancellationError { return error }
        let ns = error as NSError
        if (ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteOutOfSpaceError)
            || (ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOSPC)) { return PackError.diskFull }
        return PackError.network
    }

    static let sessionFetch: Fetch = { url, progress in
        let delegate = FetchDelegate(progress)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { c in
                delegate.continuation = c
                session.downloadTask(with: url).resume()
            }
        } onCancel: { session.invalidateAndCancel() }
    }
}

/// Callbacks kommen seriell von der Session-Queue.
private final class FetchDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    var continuation: CheckedContinuation<URL, Error>?
    private let progress: @Sendable (Double) -> Void
    private var file: URL?
    private var failure: Error?
    init(_ progress: @escaping @Sendable (Double) -> Void) { self.progress = progress }

    func urlSession(_ s: URLSession, downloadTask t: URLSessionDownloadTask, didWriteData _: Int64,
                    totalBytesWritten w: Int64, totalBytesExpectedToWrite e: Int64) {
        if e > 0 { progress(Double(w) / Double(e)) }
    }

    func urlSession(_ s: URLSession, downloadTask t: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let r = t.response as? HTTPURLResponse, !(200..<300).contains(r.statusCode) { failure = PackError.network; return }
        let keep = FileManager.default.temporaryDirectory.appendingPathComponent("dropshelf-pack-" + UUID().uuidString)
        do { try FileManager.default.moveItem(at: location, to: keep); file = keep } catch { failure = error }
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let c = continuation else { return }
        continuation = nil
        if let error = error ?? failure { c.resume(throwing: error) }
        else if let file { c.resume(returning: file) }
        else { c.resume(throwing: PackError.network) }
    }
}
