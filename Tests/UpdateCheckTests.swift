import XCTest

final class UpdateCheckTests: XCTestCase {
    func testPublicKeyValidation() {
        // 32 Byte Base64 (Format von Sparkles generate_keys).
        let valid = Data(repeating: 7, count: 32).base64EncodedString()
        XCTAssertTrue(UpdateCheck.isValidPublicKey(valid))
        XCTAssertTrue(UpdateCheck.isValidPublicKey(" \(valid) "))
        XCTAssertFalse(UpdateCheck.isValidPublicKey(nil))
        XCTAssertFalse(UpdateCheck.isValidPublicKey(""))
        XCTAssertFalse(UpdateCheck.isValidPublicKey("kein base64!"))
        XCTAssertFalse(UpdateCheck.isValidPublicKey(Data(repeating: 7, count: 31).base64EncodedString()))
        XCTAssertFalse(UpdateCheck.isValidPublicKey(Data(repeating: 7, count: 64).base64EncodedString()))
    }

    func testLegacyAutoCheckMigration() {
        XCTAssertEqual(UpdateCheck.migratedAutomaticChecks(legacy: false), false)
        XCTAssertNil(UpdateCheck.migratedAutomaticChecks(legacy: true))
        XCTAssertNil(UpdateCheck.migratedAutomaticChecks(legacy: nil))
        XCTAssertNil(UpdateCheck.migratedAutomaticChecks(legacy: "false"))
    }

    func testReleasesPage() {
        XCTAssertEqual(UpdateCheck.releasesPage.scheme, "https")
        XCTAssertEqual(UpdateCheck.releasesPage.host, "github.com")
    }
}
