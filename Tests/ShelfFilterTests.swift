import XCTest

final class ShelfFilterTests: XCTestCase {
    private var dir: URL!
    private var files: [String: URL] = [:]

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ShelfFilterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for n in ["a.png", "b.jpg", "c.pdf", "d.txt", "e.mp3", "f.mp4"] {
            let u = dir.appendingPathComponent(n)
            try Data("x".utf8).write(to: u)
            files[n] = u
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private var all: [URL] { ["a.png", "b.jpg", "c.pdf", "d.txt", "e.mp3", "f.mp4"].map { files[$0]! } }
    private func names(_ f: ShelfFilter) -> [String] { ShelfFilter.apply(all, f).map(\.lastPathComponent) }

    func testAll() { XCTAssertEqual(names(.all).count, 6) }
    func testImages() { XCTAssertEqual(names(.images), ["a.png", "b.jpg"]) }
    func testDocuments() { XCTAssertEqual(names(.documents), ["c.pdf", "d.txt"]) }
    func testMedia() { XCTAssertEqual(names(.media), ["e.mp3", "f.mp4"]) }

    func testRecent() {
        XCTAssertEqual(names(.recent(2)), ["e.mp3", "f.mp4"])
        XCTAssertEqual(names(.recent(99)).count, 6)
        XCTAssertEqual(names(.recent(0)), [])
        XCTAssertEqual(names(.recent(-1)), [])
    }

    func testTag() throws {
        try FinderTags.setTags(["Rot"], on: files["c.pdf"]!)
        try FinderTags.setTags(["Rot", "Blau"], on: files["f.mp4"]!)
        XCTAssertEqual(names(.tag("Rot")), ["c.pdf", "f.mp4"])
        XCTAssertEqual(names(.tag("Blau")), ["f.mp4"])
        XCTAssertEqual(names(.tag("Gelb")), [])
    }
}
