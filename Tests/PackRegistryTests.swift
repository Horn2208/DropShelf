import XCTest
import UniformTypeIdentifiers

final class PackRegistryTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let n = "dropshelf-registry-" + UUID().uuidString
        let d = UserDefaults(suiteName: n)!
        d.removePersistentDomain(forName: n)
        return d
    }
    private let pack = Pack(id: "zzpack", version: "2.0", url: URL(string: "https://example.invalid/x")!, sha256: "00", formats: ["zzq"], apiVersion: 1)

    func testMarkInstalledAndRemove() throws {
        let d = defaults()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("reg-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = dir.appendingPathComponent("zzpack.dylib")
        try Data("x".utf8).write(to: f)
        XCTAssertFalse(PackRegistry.isInstalled("zzpack", d))
        PackRegistry.markInstalled(pack, at: f, d)
        XCTAssertTrue(PackRegistry.isInstalled("zzpack", d))
        XCTAssertEqual(PackRegistry.installedURL("zzpack", d), f)
        XCTAssertEqual(PackRegistry.installedVersion("zzpack", d), "2.0")
        PackRegistry.remove("zzpack", d)
        XCTAssertFalse(PackRegistry.isInstalled("zzpack", d))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
    }

    func testMissingFileCountsAsNotInstalled() {
        let d = defaults()
        PackRegistry.markInstalled(pack, at: URL(fileURLWithPath: "/nonexistent/zzpack.dylib"), d)
        XCTAssertFalse(PackRegistry.isInstalled("zzpack", d))
    }

    func testConvertWithoutInstalledPackThrowsCodecMissing() async throws {
        let src = FileManager.default.temporaryDirectory.appendingPathComponent("reg-\(UUID().uuidString).txt")
        try Data("hi".utf8).write(to: src)
        defer { try? FileManager.default.removeItem(at: src) }
        let saved = ConverterRegistry.packManifest
        ConverterRegistry.packManifest = PackManifest(packs: [pack])
        defer { ConverterRegistry.packManifest = saved }
        let zzq = try XCTUnwrap(UTType(filenameExtension: "zzq"))
        do { _ = try await ConverterRegistry.convert(src, to: zzq); XCTFail("codecMissing erwartet") }
        catch ConvertError.codecMissing(let id) { XCTAssertEqual(id, "zzpack") }
    }

    func testBuiltInConversionUnchangedWithManifest() async throws {
        let src = FileManager.default.temporaryDirectory.appendingPathComponent("reg-\(UUID().uuidString).txt")
        try Data("hi".utf8).write(to: src)
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("regc-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: cache) }
        let saved = ConverterRegistry.packManifest
        ConverterRegistry.packManifest = PackManifest(packs: [pack])
        defer { ConverterRegistry.packManifest = saved }
        let out = try await ConverterRegistry.convert(src, to: .rtf, mode: .besideOriginal, cacheDir: cache)
        defer { try? FileManager.default.removeItem(at: out) }
        XCTAssertEqual(out.pathExtension, "rtf")
    }

    func testMenuMarksPackTargetsAsPending() {
        let m = PackManifest(packs: [Pack(id: "jxlp", version: "1", url: pack.url, sha256: "00", formats: ["jxl", "webm"], apiVersion: 1)])
        let ts = ConvertMenu.packTargets(from: .png, manifest: m, existing: [.png, .jpeg]) { _ in false }
        XCTAssertTrue(ts.allSatisfy { $0.pending && $0.packID == "jxlp" })
        XCTAssertTrue(ts.allSatisfy { ($0.type.conforms(to: .image)) })  // webm (Video) passt nicht zu einem Bild
        XCTAssertTrue(ts.first?.menuTitle.contains("lädt bei Bedarf") ?? false)
        XCTAssertTrue(ConvertMenu.packTargets(from: .png, manifest: m, existing: []) { _ in true }.allSatisfy { !$0.pending })
    }
}
