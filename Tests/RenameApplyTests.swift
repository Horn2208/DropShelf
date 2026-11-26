import XCTest

/// Nur eigener Temp-Ordner und ein lokal erzeugtes `Shelf` (nie Shelf.shared/ShelfManager): ohne `ShelfManager`
/// ist `onChange` nil bzw. ein Test-Zähler, es wird also nichts persistiert.
final class RenameApplyTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("RenameApplyTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        try FileManager.default.removeItem(at: dir)
    }

    private func make(_ names: String...) throws {
        for n in names { try Data(n.utf8).write(to: dir.appendingPathComponent(n)) }
    }
    private func content(_ name: String) -> String? {
        (try? Data(contentsOf: dir.appendingPathComponent(name))).map { String(decoding: $0, as: UTF8.self) }
    }
    private func listing() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
    }

    func testSwap() throws {
        try make("a.txt", "b.txt")
        let map = try Organize.applyRenames([("a.txt", "b.txt", nil), ("b.txt", "a.txt", nil)], in: dir)
        XCTAssertEqual(content("b.txt"), "a.txt")
        XCTAssertEqual(content("a.txt"), "b.txt")
        XCTAssertEqual(map[dir.appendingPathComponent("a.txt")], dir.appendingPathComponent("b.txt"))
        XCTAssertEqual(try listing(), ["a.txt", "b.txt"])  // keine Zwischennamen übrig
    }

    func testSkipsProblemsAndUnchangedAndCaseOnlyRename() throws {
        try make("a.txt", "x.txt", "y.txt")
        let map = try Organize.applyRenames([("a.txt", "A.txt", nil), ("x.txt", "x.txt", nil), ("y.txt", "z.txt", "Doppelter Zielname")], in: dir)
        XCTAssertEqual(map.count, 1)
        XCTAssertEqual(try listing(), ["A.txt", "x.txt", "y.txt"])
    }

    func testForeignTargetIsNotOverwritten() throws {
        try make("a.txt", "b.txt", "c.txt")
        // b.txt wird nicht umbenannt → fremdes Ziel; nichts darf passieren.
        XCTAssertThrowsError(try Organize.applyRenames([("c.txt", "d.txt", nil), ("a.txt", "b.txt", nil)], in: dir)) {
            XCTAssertEqual($0 as? RenameError, .targetExists("b.txt"))
        }
        XCTAssertEqual(try listing(), ["a.txt", "b.txt", "c.txt"])
        XCTAssertEqual(content("b.txt"), "b.txt")
    }

    func testFailureMidRunRollsBack() throws {
        try make("a.txt", "b.txt", "c.txt")
        let plan: [RenameStep] = [("a.txt", "b.txt", nil), ("b.txt", "c.txt", nil), ("c.txt", "a.txt", nil)]
        for failAt in 1...6 {  // jeder Schritt in Stufe 1 und 2
            var n = 0
            XCTAssertThrowsError(try Organize.applyRenames(plan, in: dir) { from, to in
                n += 1
                if n == failAt { throw CocoaError(.fileWriteUnknown) }
                try FileManager.default.moveItem(at: from, to: to)
            }, "failAt \(failAt)")
            XCTAssertEqual(try listing(), ["a.txt", "b.txt", "c.txt"], "failAt \(failAt)")
            for name in ["a.txt", "b.txt", "c.txt"] { XCTAssertEqual(content(name), name) }
        }
    }

    func testReadOnlyFolderGivesGermanError() throws {
        try make("a.txt")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        XCTAssertThrowsError(try Organize.applyRenames([("a.txt", "b.txt", nil)], in: dir)) {
            XCTAssertEqual($0 as? RenameError, .noWriteAccess(folder: dir.lastPathComponent))
            XCTAssertTrue($0.localizedDescription.hasPrefix("Kein Schreibzugriff"))
        }
        XCTAssertEqual(try listing(), ["a.txt"])
    }

    @MainActor
    func testRenameItemsUpdatesLocalShelf() throws {
        try make("a.txt", "b.txt", "keep.txt")
        let shelf = Shelf()
        var changes = 0
        shelf.onChange = { changes += 1 }
        for n in ["a.txt", "keep.txt", "b.txt"] { shelf.add(dir.appendingPathComponent(n)) }
        changes = 0
        let ids = shelf.items.map(\.id)
        let hadBookmark = shelf.items.map { $0.bookmark != nil }

        try Organize.renameItems([("a.txt", "b.txt", nil), ("b.txt", "a.txt", nil)], in: dir, shelf: shelf)

        XCTAssertEqual(shelf.items.map(\.url.lastPathComponent), ["b.txt", "keep.txt", "a.txt"])
        XCTAssertEqual(shelf.items.map(\.id), ids)
        XCTAssertEqual(changes, 1)
        for (i, item) in shelf.items.enumerated() {
            XCTAssertEqual(item.bookmark != nil, hadBookmark[i])
            guard let data = item.bookmark else { continue }
            var stale = false
            let resolved = try URL(resolvingBookmarkData: data, options: .withSecurityScope, bookmarkDataIsStale: &stale)
            XCTAssertEqual(resolved.standardizedFileURL.resolvingSymlinksInPath().path,
                           item.url.standardizedFileURL.resolvingSymlinksInPath().path)
        }
        XCTAssertEqual(content(shelf.items[0].url.lastPathComponent), "a.txt")
        shelf.discard(keepItems: true)  // nur Scopes freigeben; Temp-Dateien sind keine Cache-Dateien
    }

    @MainActor
    func testForgottenBookmarkStaysNil() throws {
        try make("a.txt")
        let shelf = Shelf()
        shelf.add(dir.appendingPathComponent("a.txt"))
        shelf.forgetBookmarks()
        shelf.replaceURLs([dir.appendingPathComponent("a.txt"): dir.appendingPathComponent("z.txt")])
        XCTAssertEqual(shelf.items.first?.url.lastPathComponent, "z.txt")
        XCTAssertNil(shelf.items.first?.bookmark)
        shelf.discard(keepItems: true)
    }
}
