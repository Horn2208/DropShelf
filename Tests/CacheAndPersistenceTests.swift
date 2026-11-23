import XCTest

/// Hostless: Es werden nur reine Funktionen und Temp-Verzeichnisse benutzt.
/// Nie anfassen: Application Support/Containers von DropShelf, `HistoryStore.shared`, `ShelfManager.shared`,
/// `ClipboardStore.shared`, `Shelf.cleanCache` (zeigt hart auf Caches/DropShelf).
@MainActor
final class CacheAndPersistenceTests: XCTestCase {
    private var tmp: URL!

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("dropshelf-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: Shelf.isCacheFile (nur Pfadlogik; es wird nichts im echten Cache angelegt)

    func testIsCacheFile() {
        let cache = Shelf.cacheDir
        XCTAssertTrue(Shelf.isCacheFile(cache.appendingPathComponent("Bild ab12cd.png")))
        XCTAssertTrue(Shelf.isCacheFile(cache.appendingPathComponent("sub/x.txt")))
        XCTAssertTrue(Shelf.isCacheFile(cache.appendingPathComponent("sub/../x.txt")))
        XCTAssertFalse(Shelf.isCacheFile(cache), "das Cache-Verzeichnis selbst ist keine Cache-Datei")
        XCTAssertFalse(Shelf.isCacheFile(tmp.appendingPathComponent("x.txt")))
        XCTAssertFalse(Shelf.isCacheFile(URL(fileURLWithPath: "/etc/hosts")))
    }

    func testSiblingDirectorySharingPrefixIsNotCache() {
        let sibling = cacheSibling("DropShelf-evil").appendingPathComponent("x.txt")
        XCTAssertFalse(Shelf.isCacheFile(sibling))
        XCTAssertFalse(Shelf.isCacheFile(cacheSibling(Shelf.cacheDir.lastPathComponent + "2").appendingPathComponent("x.txt")))
    }

    func testDotDotTraversalIsNotCache() {
        let cache = Shelf.cacheDir
        XCTAssertFalse(Shelf.isCacheFile(cache.appendingPathComponent("../x.txt")))
        XCTAssertFalse(Shelf.isCacheFile(cache.appendingPathComponent("sub/../../x.txt")))
        XCTAssertFalse(Shelf.isCacheFile(URL(fileURLWithPath: cache.path + "/../DropShelf-evil/x.txt")))
    }

    func testSymlinkOutsideCachePointingToOutsideIsNotCache() throws {
        let target = tmp.appendingPathComponent("target.txt")
        try Data("x".utf8).write(to: target)
        let link = tmp.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertFalse(Shelf.isCacheFile(link))
        XCTAssertEqual(Shelf.canonical(link), Shelf.canonical(target), "Symlinks werden aufgelöst")
    }

    // Lücke: „Symlink IM Cache zeigt nach außen" und cleanCache/discard/purgeOrphans sind nicht testbar,
    // weil `cacheDir` hart auf ~/Library/Caches/DropShelf zeigt (kein Temp-Pfad injizierbar).

    private func cacheSibling(_ name: String) -> URL {
        Shelf.cacheDir.deletingLastPathComponent().appendingPathComponent(name)
    }

    // MARK: ShelfRecord

    func testShelfRecordRoundTrip() throws {
        let r = ShelfRecord(id: UUID(), origin: CGPoint(x: -10.5, y: 20), bookmarks: [Data([1, 2, 3]), Data()])
        let r2 = ShelfRecord(id: UUID(), origin: .zero, bookmarks: [])
        XCTAssertEqual(ShelfRecord.decode(try ShelfRecord.encode([r, r2])), [r, r2])
        XCTAssertEqual(ShelfRecord.decode(try ShelfRecord.encode([])), [])
    }

    func testShelfRecordDecodeBadData() {
        XCTAssertEqual(ShelfRecord.decode(Data("kaputt".utf8)), [])
        XCTAssertEqual(ShelfRecord.decode(Data()), [])
        XCTAssertEqual(ShelfRecord.decode(Data("{}".utf8)), [], "Objekt statt Array")
        XCTAssertEqual(ShelfRecord.decode(Data("[]".utf8)), [])
    }

    /// Ein Eintrag ohne `bookmarks` (und ein `null`) wird übersprungen, die guten bleiben.
    func testShelfRecordBadEntryKeepsOthers() throws {
        let record = ShelfRecord(id: UUID(), origin: .zero, bookmarks: [Data([1])])
        var arr = try XCTUnwrap(JSONSerialization.jsonObject(with: ShelfRecord.encode([record])) as? [Any])
        arr.append(["id": UUID().uuidString, "origin": [1, 2]])  // kein "bookmarks"
        arr.append(NSNull())
        let mixed = try JSONSerialization.data(withJSONObject: arr)
        XCTAssertEqual(ShelfRecord.decode(mixed), [record])
        let result: (items: [ShelfRecord], complete: Bool)? = PersistedList.decode(mixed)
        XCTAssertEqual(result?.complete, false)
    }

    func testOldSchemaEntriesGetDefaults() throws {
        let shelf: [ShelfRecord] = ShelfRecord.decode(Data(#"[{"bookmarks":["AQID"]}]"#.utf8))
        XCTAssertEqual(shelf.first?.origin, .zero)
        XCTAssertEqual(shelf.first?.bookmarks, [Data([1, 2, 3])])
        let history: (items: [HistoryStore.Record], complete: Bool)? = PersistedList.decode(Data(#"[{"bookmarks":["AQID"]}]"#.utf8))
        XCTAssertEqual(history?.complete, true)
        XCTAssertEqual(history?.items.first?.date, PersistedList.unknownDate)
    }

    // MARK: PersistedList (nur Temp-Dateien)

    func testCorruptFilesGetSeparateBackups() throws {
        let file = tmp.appendingPathComponent("shelves.json")
        let first = Data("kaputt 1".utf8), second = Data("kaputt 2".utf8)
        try first.write(to: file)
        var r: (items: [ShelfRecord], writable: Bool) = PersistedList.load(file)
        XCTAssertTrue(r.items.isEmpty); XCTAssertTrue(r.writable)
        XCTAssertEqual(try Data(contentsOf: file), first, "Laden verändert das Original nicht")
        r = PersistedList.load(file)  // gleiche Bytes: keine zweite Sicherung
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path + ".corrupt.1"))
        try second.write(to: file)
        r = PersistedList.load(file)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: file.path + ".corrupt")), first)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: file.path + ".corrupt.1")), second)
    }

    func testPartlyBadFileKeepsGoodEntriesAndBacksUp() throws {
        let file = tmp.appendingPathComponent("history.json")
        let bytes = Data(#"[{"id":"\#(UUID())","date":1,"bookmarks":["AQID"]},{"date":1}]"#.utf8)
        try bytes.write(to: file)
        let r: (items: [HistoryStore.Record], writable: Bool) = PersistedList.load(file)
        XCTAssertEqual(r.items.count, 1); XCTAssertTrue(r.writable)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: file.path + ".corrupt")), bytes)
    }

    func testMissingFileIsEmptyWithoutBackup() {
        let file = tmp.appendingPathComponent("missing.json")
        let r: (items: [ClipEntry], writable: Bool) = PersistedList.load(file)
        XCTAssertTrue(r.items.isEmpty); XCTAssertTrue(r.writable)
        XCTAssertFalse(PersistedList.hasBackup(of: file))
    }

    func testUnreadableFileIsNotWritable() throws {
        let file = tmp.appendingPathComponent("dir.json")  // Verzeichnis statt Datei: echter Lesefehler
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        let r: (items: [ShelfRecord], writable: Bool) = PersistedList.load(file)
        XCTAssertTrue(r.items.isEmpty); XCTAssertFalse(r.writable)
        XCTAssertFalse(PersistedList.hasBackup(of: file))
    }

    func testClipboardNeverGetsBackup() throws {
        let file = tmp.appendingPathComponent("index.json")
        let corrupt = Data("geheim".utf8)
        try corrupt.write(to: file)
        var r: (items: [ClipEntry], writable: Bool) = PersistedList.load(file, keepBackup: false)
        XCTAssertTrue(r.items.isEmpty); XCTAssertFalse(r.writable, "unlesbarer Verlauf wird nicht überschrieben")
        XCTAssertEqual(try Data(contentsOf: file), corrupt)
        try Data(#"[{"kind":"text","key":"t:a","text":"a"},{"kind":"bogus"}]"#.utf8).write(to: file)
        r = PersistedList.load(file, keepBackup: false)
        XCTAssertEqual(r.items.map(\.key), ["t:a"]); XCTAssertTrue(r.writable, "teilweise lesbar darf neu geschrieben werden")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: tmp.path), ["index.json"], "keine Kopie")
    }

    func testCurrentFormatRoundTripsUnchanged() throws {
        let id = UUID().uuidString
        try assertRoundTrip([ShelfRecord].self, #"[{"id":"\#(id)","origin":[1.5,2],"bookmarks":["AQID"]}]"#)
        try assertRoundTrip([HistoryStore.Record].self, #"[{"id":"\#(id)","date":700000000.5,"bookmarks":["AQID"]}]"#)
        try assertRoundTrip([ClipEntry].self, #"[{"id":"\#(id)","kind":"text","key":"t:a","text":"a","date":700000000.5,"app":"App","bundle":"b.c","pinned":true}]"#)
    }

    private func assertRoundTrip<T: Codable>(_: [T].Type, _ json: String) throws {
        let file = tmp.appendingPathComponent(UUID().uuidString + ".json")
        try Data(json.utf8).write(to: file)
        let r: (items: [T], writable: Bool) = PersistedList.load(file)
        XCTAssertEqual(r.items.count, 1); XCTAssertTrue(r.writable)
        XCTAssertFalse(PersistedList.hasBackup(of: file))
        let out = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(r.items)) as? NSArray)
        XCTAssertEqual(out, try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? NSArray))
    }

    // MARK: HistoryStore.Record

    func testHistoryRecordRoundTrip() throws {
        let r = HistoryStore.Record(id: UUID(), date: Date(timeIntervalSince1970: 1_700_000_000), bookmarks: [Data([9, 8])])
        let back = try JSONDecoder().decode([HistoryStore.Record].self, from: JSONEncoder().encode([r]))
        XCTAssertEqual(back.count, 1)
        XCTAssertEqual(back[0].id, r.id)
        XCTAssertEqual(back[0].date, r.date)
        XCTAssertEqual(back[0].bookmarks, r.bookmarks)
    }

    func testHistoryRecordBadData() {
        let dec = JSONDecoder()
        XCTAssertThrowsError(try dec.decode([HistoryStore.Record].self, from: Data()))
        XCTAssertThrowsError(try dec.decode([HistoryStore.Record].self, from: Data("kaputt".utf8)))
        XCTAssertThrowsError(try dec.decode([HistoryStore.Record].self, from: Data("[{\"id\":\"\(UUID())\"}]".utf8)), "fehlendes date/bookmarks")
        // Die App lädt über `PersistedList.load`: solche Einträge werden übersprungen und gesichert.
    }

    // MARK: ClipEntry

    func testClipEntryRoundTrip() throws {
        var e = ClipEntry(kind: .files, key: "f:/a", paths: ["/a", "/b"])
        e.text = "t"; e.image = "x.png"; e.meta = "1×1"; e.app = "App"; e.bundle = "b.c"; e.pinned = true
        e.date = Date(timeIntervalSince1970: 1_700_000_000)
        let b = try JSONDecoder().decode([ClipEntry].self, from: JSONEncoder().encode([e]))[0]
        XCTAssertEqual(b.id, e.id); XCTAssertEqual(b.kind, .files); XCTAssertEqual(b.key, e.key)
        XCTAssertEqual(b.text, "t"); XCTAssertEqual(b.paths, ["/a", "/b"]); XCTAssertEqual(b.image, "x.png")
        XCTAssertEqual(b.meta, "1×1"); XCTAssertEqual(b.date, e.date); XCTAssertEqual(b.app, "App")
        XCTAssertEqual(b.bundle, "b.c"); XCTAssertTrue(b.pinned)
    }

    func testClipEntryDecodeBadAndOldSchemaDefaults() throws {
        let dec = JSONDecoder()
        XCTAssertThrowsError(try dec.decode([ClipEntry].self, from: Data()))
        XCTAssertThrowsError(try dec.decode([ClipEntry].self, from: Data("kaputt".utf8)))
        XCTAssertThrowsError(try dec.decode([ClipEntry].self, from: Data("[{\"kind\":\"text\"}]".utf8)), "ohne key")
        XCTAssertThrowsError(try dec.decode([ClipEntry].self, from: Data("[{\"kind\":\"bogus\",\"key\":\"k\"}]".utf8)), "unbekannte Art")
        // Altes Schema: id/date/pinned bekommen Ersatzwerte, der Inhalt bleibt.
        let enc = try JSONEncoder().encode([ClipEntry(kind: .text, key: "t:a", text: "a")])
        var obj = try XCTUnwrap(JSONSerialization.jsonObject(with: enc) as? [[String: Any]])
        for k in ["id", "date", "pinned"] { obj[0].removeValue(forKey: k) }
        let old = try XCTUnwrap(dec.decode([ClipEntry].self, from: JSONSerialization.data(withJSONObject: obj)).first)
        XCTAssertEqual(old.text, "a"); XCTAssertFalse(old.pinned); XCTAssertEqual(old.date, PersistedList.unknownDate)
        obj = try XCTUnwrap(JSONSerialization.jsonObject(with: enc) as? [[String: Any]])
        for k in ["text", "paths", "image", "meta", "app", "bundle"] { obj[0].removeValue(forKey: k) }
        XCTAssertEqual(try dec.decode([ClipEntry].self, from: JSONSerialization.data(withJSONObject: obj)).count, 1)
    }
}
