import XCTest

final class PackManifestTests: XCTestCase {
    func testPackLookupByExtension() throws {
        let json = #"{"packs":[{"id":"jxl","version":"1.0","url":"https://example.invalid/jxl.dylib","sha256":"ab","formats":["jxl"],"apiVersion":1}]}"#
        let m = try PackManifest.decode(Data(json.utf8))
        XCTAssertEqual(m.pack(for: "JXL")?.id, "jxl")
        XCTAssertEqual(m.pack(for: "jxl")?.apiVersion, 1)
        XCTAssertNil(m.pack(for: "avi"))
    }

    func testEmptyManifestDecodes() throws {
        XCTAssertTrue(try PackManifest.decode(Data(#"{"packs":[]}"#.utf8)).packs.isEmpty)
    }
}
