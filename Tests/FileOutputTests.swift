import XCTest

/// Hostless: nur eigener Temp-Ordner; `cacheDir` zeigt nie auf den echten Cache (`Shelf.cacheDir`).
final class FileOutputTests: XCTestCase {
    private var tmp: URL!
    private var dir: URL!
    private var cache: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        tmp = fm.temporaryDirectory.appendingPathComponent("dropshelf-fileoutput-" + UUID().uuidString)
        dir = tmp.appendingPathComponent("Downloads")
        cache = tmp.appendingPathComponent("cache")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        try? fm.removeItem(at: tmp)
    }

    private func file(_ name: String, in folder: URL? = nil, _ text: String) throws -> URL {
        let url = (folder ?? tmp).appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func text(_ url: URL) throws -> String { String(decoding: try Data(contentsOf: url), as: UTF8.self) }

    func testFreeNameOnCollision() throws {
        let src = try file("Foto.png", in: dir, "original")
        let a = try FileOutput.place(try file("t1", "eins"), for: src, suffix: "bearbeitet", ext: "png",
                                     mode: .besideOriginal, cacheDir: cache)
        let b = try FileOutput.place(try file("t2", "zwei"), for: src, suffix: "bearbeitet", ext: "png",
                                     mode: .besideOriginal, cacheDir: cache)
        XCTAssertEqual(a, dir.appendingPathComponent("Foto (bearbeitet).png"))
        XCTAssertEqual(b, dir.appendingPathComponent("Foto (bearbeitet 2).png"))
        XCTAssertEqual(try text(a), "eins")
        XCTAssertEqual(try text(b), "zwei")
        XCTAssertEqual(FileOutput.candidateName(base: "Foto", suffix: "", ext: "jpg", n: 2), "Foto 2.jpg")
    }

    func testNeverOverwritesWithoutReplace() throws {
        let src = try file("Foto.png", in: dir, "original")
        // Ohne Suffix und mit gleicher Endung wäre der Wunschname das Original selbst.
        let out = try FileOutput.place(try file("t", "neu"), for: src, suffix: "", ext: "png",
                                       mode: .besideOriginal, cacheDir: cache)
        XCTAssertEqual(out, dir.appendingPathComponent("Foto 2.png"))
        XCTAssertEqual(try text(src), "original")

        let c = try FileOutput.placeReporting(try file("t", "cache"), for: src, suffix: "x", ext: "png",
                                              mode: .cache, cacheDir: cache)
        XCTAssertEqual(c.url.deletingLastPathComponent().standardizedFileURL, cache.standardizedFileURL)
        XCTAssertFalse(c.inCache, "Cache war gewünscht, kein Rückfall")
        XCTAssertEqual(try text(src), "original")
    }

    func testFallsBackToCacheWhenFolderReadOnly() throws {
        let src = try file("Foto.png", in: dir, "original")
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }

        let r = try FileOutput.placeReporting(try file("t", "neu"), for: src, suffix: "bearbeitet", ext: "png",
                                              mode: .besideOriginal, cacheDir: cache)
        XCTAssertEqual(r.url, cache.appendingPathComponent("Foto (bearbeitet).png"))
        XCTAssertTrue(r.inCache)
        XCTAssertEqual(r.notice, "Kein Schreibzugriff auf „Downloads“ – das Ergebnis liegt in der Ablage. Ordner freigeben, um neben das Original zu speichern.")
        XCTAssertEqual(try text(r.url), "neu")
        XCTAssertEqual(try text(src), "original")
    }

    func testReplaceOriginalKeepsNameWithNewContent() throws {
        let src = try file("Foto.png", in: dir, "original")
        let r = try FileOutput.placeReporting(try file("t", "ersetzt"), for: src, suffix: "bearbeitet", ext: "png",
                                              mode: .replaceOriginal, cacheDir: cache)
        XCTAssertFalse(r.inCache)
        XCTAssertEqual(r.url.standardizedFileURL.path, src.standardizedFileURL.path)
        XCTAssertEqual(try text(src), "ersetzt")
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: dir.path), ["Foto.png"])
    }
}
