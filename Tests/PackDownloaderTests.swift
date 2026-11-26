import XCTest
import CryptoKit

final class PackDownloaderTests: XCTestCase {
    private var tmp: URL!
    private let fm = FileManager.default
    private let payload = Data("pretend dylib".utf8)

    override func setUpWithError() throws {
        tmp = fm.temporaryDirectory.appendingPathComponent("dropshelf-packs-" + UUID().uuidString)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? fm.removeItem(at: tmp) }

    private func pack(hash: String? = nil) throws -> Pack {
        let src = tmp.appendingPathComponent("src.bin")
        try payload.write(to: src)
        let h = hash ?? SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        return Pack(id: "jxl", version: "1.0", url: src, sha256: h, formats: ["jxl"], apiVersion: 1)
    }

    func testWrongHashThrowsAndStoresNothing() async throws {
        let root = tmp.appendingPathComponent("root")
        let d = PackDownloader(root: root)
        do { _ = try await d.install(try pack(hash: "00"), progress: { _ in }); XCTFail("hashMismatch erwartet") }
        catch PackError.hashMismatch {}
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("jxl").path))
    }

    func testCorrectHashStoresFileAndRemovesOldVersion() async throws {
        let root = tmp.appendingPathComponent("root")
        let old = root.appendingPathComponent("jxl/0.9")
        try fm.createDirectory(at: old, withIntermediateDirectories: true)
        let d = PackDownloader(root: root)
        let dest = try await d.install(try pack(), progress: { _ in })
        XCTAssertEqual(dest, root.appendingPathComponent("jxl/1.0/jxl.dylib"))
        XCTAssertEqual(try Data(contentsOf: dest), payload)
        XCTAssertFalse(fm.fileExists(atPath: old.path))
    }

    func testSecondInstallOfSameIDIsRejected() async throws {
        let slow = tmp.appendingPathComponent("slow.bin")
        try payload.write(to: slow)
        let d = PackDownloader(root: tmp.appendingPathComponent("root")) { _, _ in
            try await Task.sleep(nanoseconds: 400_000_000)
            return slow
        }
        let p = try pack()
        let first = Task { try await d.install(p, progress: { _ in }) }
        try await Task.sleep(nanoseconds: 100_000_000)
        do { _ = try await d.install(p, progress: { _ in }); XCTFail("alreadyRunning erwartet") }
        catch PackError.alreadyRunning {}
        _ = try await first.value
    }
}
