import XCTest

/// Hostless: Temp-Datei im eigenen Temp-Ordner.
final class FinderTagsTests: XCTestCase {
    private var dir: URL!
    private var file: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        dir = fm.temporaryDirectory.appendingPathComponent("dropshelf-tags-" + UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        file = dir.appendingPathComponent("a.txt")
        try Data("x".utf8).write(to: file)
    }

    override func tearDownWithError() throws { try? fm.removeItem(at: dir) }

    func testStandardNames() {
        XCTAssertEqual(FinderTags.standardNames, ["Rot", "Orange", "Gelb", "Grün", "Blau", "Lila", "Grau"])
    }

    func testSetAndRead() throws {
        XCTAssertEqual(FinderTags.tags(of: file), [])
        try FinderTags.setTags(["Rot", "Projekt"], on: file)
        XCTAssertEqual(Set(FinderTags.tags(of: file)), ["Rot", "Projekt"])
    }

    func testAddNoDuplicateAndRemoveKeepsOthers() throws {
        try FinderTags.setTags(["Projekt"], on: file)
        try FinderTags.addTag("Blau", to: file)
        try FinderTags.addTag("Blau", to: file)
        XCTAssertEqual(FinderTags.tags(of: file).filter { $0 == "Blau" }.count, 1)
        try FinderTags.setTags(["Gelb", "Gelb"], on: file)
        XCTAssertEqual(FinderTags.tags(of: file), ["Gelb"])
        try FinderTags.setTags(["Projekt", "Blau"], on: file)
        try FinderTags.removeTag("Blau", from: file)
        XCTAssertEqual(FinderTags.tags(of: file), ["Projekt"])
        try FinderTags.removeTag("Nix", from: file)
        XCTAssertEqual(FinderTags.tags(of: file), ["Projekt"])
    }
}
