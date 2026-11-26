import XCTest

/// Baut im Testlauf eine eigene Test-Dylib (nie ein echter Codec, nie committet).
final class CodecLoaderTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("dropshelf-codec-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    private func makeDylib() throws -> URL {
        let c = tmp.appendingPathComponent("t.c"), out = tmp.appendingPathComponent("testcodec.dylib")
        try "int dsc_api_version(void) { return 7; }\n".write(to: c, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        p.arguments = ["clang", "-dynamiclib", "-o", out.path, c.path]
        try p.run(); p.waitUntilExit()
        try XCTSkipIf(p.terminationStatus != 0, "clang nicht verfügbar")
        return out
    }

    func testLoadChecksAPIVersion() throws {
        let url = try makeDylib()
        let h = try CodecLoader.load(url, expectedAPI: 7)
        XCTAssertEqual(h.id, "testcodec")
        let f = try h.symbol("dsc_api_version", as: CodecABI.APIVersion.self)
        XCTAssertEqual(f(), 7)
    }

    func testWrongAPIVersionThrows() throws {
        let url = try makeDylib()
        XCTAssertThrowsError(try CodecLoader.load(url, expectedAPI: 8)) {
            guard case CodecError.apiMismatch(let found, let expected) = $0 else { return XCTFail("\($0)") }
            XCTAssertEqual([found, expected], [7, 8])
        }
    }

    func testMissingSymbolThrows() throws {
        let h = try CodecLoader.load(try makeDylib(), expectedAPI: 7)
        XCTAssertThrowsError(try h.symbol("dsc_gibts_nicht", as: CodecABI.APIVersion.self)) {
            guard case CodecError.symbolMissing = $0 else { return XCTFail("\($0)") }
        }
    }

    func testMissingFileThrowsLoadFailed() {
        XCTAssertThrowsError(try CodecLoader.load(tmp.appendingPathComponent("nope.dylib"), expectedAPI: 1)) {
            guard case CodecError.loadFailed = $0 else { return XCTFail("\($0)") }
        }
    }
}
