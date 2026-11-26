import XCTest
import DropShelfCodecs

final class DropShelfCodecsTests: XCTestCase {
    func testPackageLinksAndListsEncoders() {
        XCTAssertFalse(DropShelfCodecs.version.isEmpty)
        let enc = Set(DropShelfCodecs.availableEncoders)
        XCTAssertTrue(enc.contains("ogg-vorbis"))
        XCTAssertTrue(enc.contains("ogg-opus"))
        XCTAssertTrue(enc.contains("flac"))
        XCTAssertTrue(enc.contains("mp3"))
        XCTAssertTrue(enc.contains("webp"))
        XCTAssertTrue(enc.contains("wavpack"))
    }
}
