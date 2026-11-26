import XCTest

/// Hostless: eigener Temp-Ordner und eigene UserDefaults-Suite (nie echte Nutzerdaten oder NSOpenPanel).
/// Hinweis: Security-Scope-Bookmarks funktionieren im unsandboxed Testprozess auch ohne aktiven Scope;
/// diese Tests prüfen die Store-, Pfad-, Scope-Zähler- und Integrationslogik.
final class FolderAccessTests: XCTestCase {
    private var tmp: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        tmp = fm.temporaryDirectory.appendingPathComponent("dropshelf-folderaccess-" + UUID().uuidString)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        suiteName = "com.horn2208.DropShelf.tests.folderaccess." + UUID().uuidString
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDownWithError() throws {
        // Eventuell auf 0o555 gesetzte Ordner wieder schreibbar machen vor dem Löschen
        if let items = try? fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil) {
            for item in items {
                try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: item.path)
            }
        }
        try? fm.removeItem(at: tmp)
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeDir(_ name: String) throws -> URL {
        let u = tmp.appendingPathComponent(name)
        try fm.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    func testAddAllAndRemoveTwoFolders() throws {
        let a = try makeDir("OrdnerA")
        let b = try makeDir("OrdnerB")
        let store = FolderAccessStore(userDefaults: defaults)

        try store.add(a)
        try store.add(b)
        try store.add(a) // Duplikat darf nicht doppelt erscheinen

        let paths = Set(store.all().map { FolderAccessStore.normalize($0).path })
        XCTAssertEqual(paths, Set([FolderAccessStore.normalize(a).path, FolderAccessStore.normalize(b).path]))
        XCTAssertEqual(store.entries().count, 2)

        store.remove(a)
        let afterRemove = store.all().map { FolderAccessStore.normalize($0).path }
        XCTAssertEqual(afterRemove, [FolderAccessStore.normalize(b).path])
    }

    func testCoveringDirectNestedOutsidePrefixAndSymlink() throws {
        let allowed = try makeDir("Freigegeben")
        let nested = allowed.appendingPathComponent("Unterordner")
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        let sibling = try makeDir("Freigegeben2") // gleiches Präfix, darf NICHT matchen!
        let outside = try makeDir("Fremd")

        let fileDirect = allowed.appendingPathComponent("a.txt")
        let fileNested = nested.appendingPathComponent("b.txt")
        let fileSibling = sibling.appendingPathComponent("c.txt")
        let fileOutside = outside.appendingPathComponent("d.txt")
        for f in [fileDirect, fileNested, fileSibling, fileOutside] { try Data("x".utf8).write(to: f) }

        let symlinkDir = tmp.appendingPathComponent("LinkZuFreigegeben")
        try fm.createSymbolicLink(at: symlinkDir, withDestinationURL: allowed)
        let fileViaSymlink = symlinkDir.appendingPathComponent("a.txt")

        let store = FolderAccessStore(userDefaults: defaults)
        try store.add(allowed)
        let expectedPath = FolderAccessStore.normalize(allowed).path

        XCTAssertEqual(store.covering(fileDirect).map { FolderAccessStore.normalize($0).path }, expectedPath)
        XCTAssertEqual(store.covering(fileNested).map { FolderAccessStore.normalize($0).path }, expectedPath)
        XCTAssertEqual(store.covering(fileViaSymlink).map { FolderAccessStore.normalize($0).path }, expectedPath)
        XCTAssertNil(store.covering(fileSibling))
        XCTAssertNil(store.covering(fileOutside))
    }

    func testUnresolvableBookmarkIsSkippedWithoutCrash() throws {
        let valid = try makeDir("Gueltig")
        let store = FolderAccessStore(userDefaults: defaults)
        store.appendRawEntry(FolderAccessEntry(displayName: "Defekt", bookmark: Data("kaputtes-bookmark".utf8)))
        try store.add(valid)

        let resolved = store.all()
        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(FolderAccessStore.normalize(resolved[0]).path, FolderAccessStore.normalize(valid).path)
    }

    func testWithAccessCallsStopEvenOnError() throws {
        let allowed = try makeDir("Geschuetzt")
        let file = allowed.appendingPathComponent("test.txt")
        try Data("ok".utf8).write(to: file)

        final class Counter: @unchecked Sendable {
            var starts = 0
            var stops = 0
        }
        let counter = Counter()
        let store = FolderAccessStore(
            userDefaults: defaults,
            startAccess: { _ in counter.starts += 1; return true },
            stopAccess: { _ in counter.stops += 1 }
        )
        try store.add(allowed)

        // Normaler Lauf
        let seen = store.withAccess(to: file) { FolderAccessStore.normalize($0).path }
        XCTAssertEqual(seen, FolderAccessStore.normalize(allowed).path)
        XCTAssertEqual(counter.starts, 1)
        XCTAssertEqual(counter.stops, 1)

        // Fehler im Body: stop muss trotzdem aufgerufen werden
        struct DummyError: Error {}
        XCTAssertThrowsError(try store.withAccess(to: file) { _ in throw DummyError() })
        XCTAssertEqual(counter.starts, 2)
        XCTAssertEqual(counter.stops, 2)

        // Datei außerhalb: weder start noch stop, kein Fehler
        let outside = try makeDir("Draussen").appendingPathComponent("x.txt")
        try Data("x".utf8).write(to: outside)
        let fallback = store.withAccess(to: outside) { FolderAccessStore.normalize($0).path }
        XCTAssertEqual(fallback, FolderAccessStore.normalize(outside.deletingLastPathComponent()).path)
        XCTAssertEqual(counter.starts, 2)
        XCTAssertEqual(counter.stops, 2)
    }

    func testFileOutputUsesFolderAccessBeforeFallingBackToCache() throws {
        let dir = try makeDir("Downloads")
        let cache = tmp.appendingPathComponent("cache")
        let src = dir.appendingPathComponent("Foto.png")
        try Data("original".utf8).write(to: src)
        let tmpOut = tmp.appendingPathComponent("tmp.png")
        try Data("neu".utf8).write(to: tmpOut)

        // Simuliert Sandbox-Schreibsperre, die erst innerhalb von startAccess aufgehoben wird.
        let store = FolderAccessStore(
            userDefaults: defaults,
            startAccess: { url in
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
                return true
            },
            stopAccess: { url in
                try? FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: url.path)
            }
        )
        try store.add(dir)
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }

        let placed = try FileOutput.placeReporting(tmpOut, for: src, suffix: "bearbeitet", ext: "png",
                                                   mode: .besideOriginal, cacheDir: cache, folderAccess: store)
        XCTAssertFalse(placed.inCache, "Mit freigegebenem Ordner darf nicht in den Cache ausgewichen werden")
        XCTAssertEqual(FolderAccessStore.normalize(placed.url.deletingLastPathComponent()).path,
                       FolderAccessStore.normalize(dir).path)
        XCTAssertEqual(placed.url.lastPathComponent, "Foto (bearbeitet).png")
    }

    func testOrganizeApplyRenamesUsesFolderAccess() throws {
        let dir = try makeDir("Umbenennen")
        let a = dir.appendingPathComponent("a.txt")
        try Data("inhalt".utf8).write(to: a)

        let store = FolderAccessStore(
            userDefaults: defaults,
            startAccess: { url in
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
                return true
            },
            stopAccess: { url in
                try? FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: url.path)
            }
        )
        try store.add(dir)
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }

        let map = try Organize.applyRenames([("a.txt", "b.txt", nil)], in: dir, folderAccess: store)
        XCTAssertEqual(map.count, 1)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent("b.txt").path))
    }
}
