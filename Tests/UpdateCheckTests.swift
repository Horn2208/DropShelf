import XCTest

final class UpdateCheckTests: XCTestCase {
    func testVersionCompare() {
        XCTAssertTrue(UpdateCheck.isNewer("1.2.10", than: "1.2.9"))
        XCTAssertTrue(UpdateCheck.isNewer("v0.2", than: "0.1"))
        XCTAssertTrue(UpdateCheck.isNewer("V1.0.1", than: "1.0"))
        XCTAssertFalse(UpdateCheck.isNewer("1.2", than: "1.2.0"))
        XCTAssertFalse(UpdateCheck.isNewer("1.2.0", than: "1.2"))
        XCTAssertFalse(UpdateCheck.isNewer("0.1", than: "0.1"))
        XCTAssertFalse(UpdateCheck.isNewer("0.0.9", than: "0.1"))
    }

    func testInvalidTags() {
        for t in ["", "v", "abc", "1.x", "1..2", "v1.2-beta", "-1.0", "1.2.", "١.٢"] {
            XCTAssertFalse(UpdateCheck.isNewer(t, than: "0.1"), t)
        }
        XCTAssertFalse(UpdateCheck.isNewer("2.0", than: "kaputt"))
    }

    func testParseRelease() {
        let json = #"{"url":"x","tag_name":"v0.2.0","name":"DropShelf 0.2","html_url":"https://github.com/Horn2208/DropShelf/releases/tag/v0.2.0","assets":[]}"#
        let r = UpdateCheck.parseRelease(Data(json.utf8))
        XCTAssertEqual(r?.tag, "v0.2.0")
        XCTAssertEqual(r?.version, "0.2.0")
        XCTAssertEqual(r?.url.absoluteString, "https://github.com/Horn2208/DropShelf/releases/tag/v0.2.0")
        XCTAssertNil(UpdateCheck.parseRelease(Data(#"{"message":"Not Found"}"#.utf8)))
        XCTAssertNil(UpdateCheck.parseRelease(Data("kein json".utf8)))
        XCTAssertNil(UpdateCheck.parseRelease(Data(#"{"tag_name":"v1","html_url":"file:///etc/passwd"}"#.utf8)))
    }

    private func release(_ assets: String) -> ReleaseInfo? {
        UpdateCheck.parseRelease(Data(#"{"tag_name":"v0.3","html_url":"https://github.com/Horn2208/DropShelf/releases/tag/v0.3","assets":[\#(assets)]}"#.utf8))
    }
    private func asset(_ name: String, _ url: String) -> String { #"{"name":"\#(name)","browser_download_url":"\#(url)"}"# }

    func testDMGAssetSelection() {
        let gh = "https://github.com/Horn2208/DropShelf/releases/download/v0.3/"
        // Troll wird übersprungen (case-insensitiv), zip ignoriert, erstes passendes DMG gewinnt.
        let r = release([asset("DropShelf-src.zip", gh + "a.zip"), asset("DropShelf-TROLL.dmg", gh + "t.dmg"),
                         asset("DropShelf-0.3.DMG", gh + "d.dmg"), asset("DropShelf-alt.dmg", gh + "x.dmg")].joined(separator: ","))
        XCTAssertEqual(r?.dmg?.absoluteString, gh + "d.dmg")
        XCTAssertEqual(release(asset("x.dmg", "https://objects.githubusercontent.com/x.dmg"))?.dmg?.host, "objects.githubusercontent.com")
        // Kein DMG / nur Troll / keine assets -> nil, Release bleibt gültig.
        XCTAssertNil(release(asset("a.zip", gh + "a.zip"))?.dmg)
        XCTAssertNil(release(asset("DropShelf Troll kurz.dmg", gh + "t.dmg"))?.dmg)
        XCTAssertNotNil(release(""))
        XCTAssertNil(release("")?.dmg)
        // Fremde Domain, http, Täusch-Host -> nil.
        for u in ["https://evil.com/x.dmg", "http://github.com/x.dmg", "https://github.com.evil.com/x.dmg",
                  "https://evilgithubusercontent.com/x.dmg", "file:///tmp/x.dmg"] {
            XCTAssertNil(release(asset("x.dmg", u))?.dmg, u)
        }
    }

    func testDownloadDestinationUnique() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = UpdateCheck.downloadDestination(in: dir, version: "0.3")
        XCTAssertEqual(first.lastPathComponent, "DropShelf-0.3.dmg")
        try Data("a".utf8).write(to: first)
        let second = UpdateCheck.downloadDestination(in: dir, version: "0.3")
        XCTAssertEqual(second.lastPathComponent, "DropShelf-0.3 2.dmg")
        try Data("b".utf8).write(to: second)
        XCTAssertEqual(UpdateCheck.downloadDestination(in: dir, version: "0.3").lastPathComponent, "DropShelf-0.3 3.dmg")
        // Pfad aus dem Netz wird entschärft: bleibt im Ordner.
        let evil = UpdateCheck.downloadDestination(in: dir, version: "../../etc/x")
        XCTAssertEqual(evil.deletingLastPathComponent().standardizedFileURL, dir.standardizedFileURL)
        XCTAssertEqual(evil.pathExtension, "dmg")
        XCTAssertEqual(UpdateCheck.downloadDestination(in: dir, version: "").lastPathComponent, "DropShelf.dmg")
    }

    func testThrottle() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(UpdateCheck.shouldCheck(last: nil, now: now))
        XCTAssertFalse(UpdateCheck.shouldCheck(last: now.addingTimeInterval(-3600), now: now))
        XCTAssertFalse(UpdateCheck.shouldCheck(last: now.addingTimeInterval(-86399), now: now))
        XCTAssertTrue(UpdateCheck.shouldCheck(last: now.addingTimeInterval(-86400), now: now))
        XCTAssertTrue(UpdateCheck.shouldCheck(last: now.addingTimeInterval(3600), now: now))  // Uhr zurückgestellt
    }
}
