import XCTest
import AppKit
import PDFKit

/// Hostless: nur eigener Temp-Ordner, `cacheDir` zeigt nie auf den echten Cache; keine Fenster, keine Alerts.
@MainActor
final class EditMenuTests: XCTestCase {
    private var tmp: URL!
    private var cache: URL!
    private let fm = FileManager.default

    override func setUp() async throws {
        tmp = fm.temporaryDirectory.appendingPathComponent("dropshelf-editmenu-" + UUID().uuidString)
        cache = tmp.appendingPathComponent("cache")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() async throws { try? fm.removeItem(at: tmp) }

    private func file(_ name: String) -> URL { tmp.appendingPathComponent(name) }

    /// Kleine Text-PDF mit einer Seite (lässt sich nicht weiter verkleinern).
    private func makePDF(_ name: String) -> URL {
        let url = file(name)
        var box = CGRect(x: 0, y: 0, width: 100, height: 100)
        let ctx = CGContext(url as CFURL, mediaBox: &box, nil)!
        ctx.beginPDFPage(nil)
        ctx.fill(CGRect(x: 10, y: 10, width: 20, height: 20))
        ctx.endPDFPage()
        ctx.closePDF()
        return url
    }

    // MARK: Zielmenge

    private func items(_ names: [String]) -> [Shelf.Item] { names.map { Shelf.Item(url: file($0)) } }

    func testSelectedClickTakesWholeSelectionInDisplayOrder() {
        let i = items(["a", "b", "c"])
        var s = Selection()
        s.order = [i[2].id, i[0].id, i[1].id]  // Anzeige anders sortiert als die Ablage
        s.ids = [i[0].id, i[2].id]
        XCTAssertEqual(EditMenu.targetURLs(clicked: i[0].id, selection: s, items: i), [file("c"), file("a")])
    }

    func testUnselectedClickTakesOnlyClicked() {
        let i = items(["a", "b", "c"])
        var s = Selection()
        s.order = i.map(\.id)
        s.ids = [i[0].id, i[2].id]
        XCTAssertEqual(EditMenu.targetURLs(clicked: i[1].id, selection: s, items: i), [file("b")])
        XCTAssertEqual(EditMenu.targetURLs(clicked: i[1].id, selection: Selection(), items: i), [file("b")])
    }

    // MARK: Menüpunkte

    func testPlanNeedsTwoMergeableFiles() {
        let pdf = file("a.PDF"), img = file("b.png"), txt = file("c.txt")
        XCTAssertEqual(EditMenu.plan([pdf]), .init(merge: [], compress: [pdf], pages: pdf))
        XCTAssertEqual(EditMenu.plan([img]), .init(merge: [], compress: []))
        XCTAssertEqual(EditMenu.plan([img, txt]), .init(merge: [], compress: []))
        XCTAssertEqual(EditMenu.plan([txt, img, pdf]), .init(merge: [img, pdf], compress: [pdf], pages: pdf))
        XCTAssertEqual(EditMenu.plan([img, file("d.jpg")]), .init(merge: [img, file("d.jpg")], compress: []))
        XCTAssertTrue(EditMenu.plan([txt, file("ohne"), file("e.zip")]).isEmpty)
    }

    private func titles(_ m: NSMenu?) -> [String] { m?.items.map(\.title) ?? [] }

    func testSubmenuStructure() {
        let shelf = Shelf()
        XCTAssertNil(EditMenu.menuItem(for: [file("a.txt")], shelf: shelf))
        XCTAssertNil(EditMenu.menuItem(for: [file("a.png")], shelf: shelf))

        let one = EditMenu.menuItem(for: [file("a.pdf")], shelf: shelf)
        XCTAssertEqual(one?.title, "Bearbeiten")
        XCTAssertEqual(titles(one?.submenu), ["Komprimieren", "Seiten verwalten …"])
        XCTAssertEqual(titles(one?.submenu?.items.first?.submenu), ["Gering", "Mittel", "Stark"])

        let two = EditMenu.menuItem(for: [file("a.pdf"), file("b.png")], shelf: shelf)
        XCTAssertEqual(titles(two?.submenu), ["Zu PDF zusammenfügen", "Komprimieren", "Seiten verwalten …"])
        let images = EditMenu.menuItem(for: [file("a.png"), file("b.png")], shelf: shelf)
        XCTAssertEqual(titles(images?.submenu), ["Zu PDF zusammenfügen"])
    }

    // MARK: Rechtsklickmenü

    private func contextTitles(_ v: DragOutView) throws -> [String]? {
        let e = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                 windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        return v.menu(for: e).map { titles($0) }
    }

    private func item(_ title: String) -> () -> NSMenuItem? { { NSMenuItem(title: title, action: nil, keyEquivalent: "") } }

    func testDetailViewMenuOrder() throws {
        let v = DragOutView()
        v.onRemove = {}
        v.onAirDrop = {}
        v.convertItem = item("Umwandeln in")
        v.editItem = item("Bearbeiten")
        XCTAssertEqual(try contextTitles(v),
                       ["Per AirDrop senden", "Umwandeln in", "Im Finder zeigen", "Bearbeiten", "Entfernen"])
        v.editItem = { nil }
        XCTAssertEqual(try contextTitles(v), ["Per AirDrop senden", "Umwandeln in", "Im Finder zeigen", "Entfernen"])
    }

    func testSmallShelfMenuHasOnlyConvertAndEdit() throws {
        let v = DragOutView()
        XCTAssertNil(try contextTitles(v))
        v.convertItem = { nil }
        v.editItem = { nil }
        XCTAssertNil(try contextTitles(v))
        v.editItem = item("Bearbeiten")
        XCTAssertEqual(try contextTitles(v), ["Bearbeiten"])
        v.convertItem = item("Umwandeln in")
        XCTAssertEqual(try contextTitles(v), ["Umwandeln in", "Bearbeiten"])
    }

    func testHistoryMenuUnchanged() throws {
        let v = DragOutView()
        v.onRemove = {}
        v.onRestore = {}
        XCTAssertEqual(try contextTitles(v), ["Wiederherstellen", "Im Finder zeigen", "Entfernen"])
    }

    // MARK: Bannertexte

    func testMergeNotice() {
        XCTAssertNil(EditMenu.mergeNotice(skipped: [], notice: nil))
        XCTAssertEqual(EditMenu.mergeNotice(skipped: [file("a.txt"), file("b.zip")], notice: nil),
                       "Nicht ins PDF übernommen: „a.txt“, „b.zip“.")
        XCTAssertEqual(EditMenu.mergeNotice(skipped: [], notice: "Cache."), "Cache.")
        XCTAssertEqual(EditMenu.mergeNotice(skipped: [file("a.txt")], notice: "Cache."),
                       "Nicht ins PDF übernommen: „a.txt“.\nCache.")
    }

    func testCompressNotice() {
        XCTAssertNil(EditMenu.compressNotice(notSmaller: [], failures: [], notices: []))
        XCTAssertEqual(EditMenu.compressNotice(notSmaller: [file("a.pdf"), file("b.pdf")], failures: [], notices: []),
                       "Nicht kleiner geworden, daher nichts hinzugefügt: „a.pdf“, „b.pdf“.")
        XCTAssertEqual(EditMenu.compressNotice(notSmaller: [file("a.pdf")],
                                               failures: ["Komprimieren von „c.pdf“ fehlgeschlagen: kaputt"],
                                               notices: ["Cache X.", "Cache X.", "Cache Y."]),
                       "Komprimieren von „c.pdf“ fehlgeschlagen: kaputt\n"
                       + "Nicht kleiner geworden, daher nichts hinzugefügt: „a.pdf“.\nCache X.\nCache Y.")
    }

    // MARK: Aufträge

    func testMergeJobAddsNewFileAndNamesSkipped() throws {
        let txt = file("0.txt"); try Data("x".utf8).write(to: txt)
        let a = makePDF("a.pdf"), b = makePDF("b.pdf")
        let before = try Data(contentsOf: a)
        let o = try EditMenu.mergeJob([txt, a, b], cacheDir: cache)
        XCTAssertEqual(o.add.map(\.lastPathComponent), ["a (zusammengefügt).pdf"])  // erste PDF, nicht die übersprungene Datei
        XCTAssertEqual(PDFDocument(url: try XCTUnwrap(o.add.first))?.pageCount, 2)
        XCTAssertEqual(o.notice, "Nicht ins PDF übernommen: „0.txt“.")
        XCTAssertEqual(try Data(contentsOf: a), before)
    }

    func testMergeJobFallsBackToCacheWithFolderButton() throws {
        let a = makePDF("a.pdf"), b = makePDF("b.pdf")
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: tmp.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmp.path) }
        try XCTSkipIf(fm.isWritableFile(atPath: tmp.path), "Ordner lässt sich nicht sperren")
        cache = fm.temporaryDirectory.appendingPathComponent("dropshelf-editmenu-cache-" + UUID().uuidString)
        defer { try? fm.removeItem(at: cache) }
        let o = try EditMenu.mergeJob([a, b], cacheDir: cache)
        XCTAssertEqual(o.add.first?.deletingLastPathComponent().standardizedFileURL, cache.standardizedFileURL)
        XCTAssertEqual(o.folderFor, a)
        XCTAssertTrue(o.notice?.contains("Kein Schreibzugriff") == true)
    }

    func testCompressJobReportsNotSmallerAndBrokenAndContinues() throws {
        let broken = file("kaputt.pdf"); try Data("kein pdf".utf8).write(to: broken)
        let small = makePDF("klein.pdf")
        // Erst einmal komprimieren, damit der zweite Lauf sicher nichts mehr spart.
        let once = try PDFTools.compress(small, level: .low, cacheDir: cache)
        let input = once.url
        let o = EditMenu.compressJob([broken, input], level: .low, cacheDir: cache)
        XCTAssertTrue(o.add.isEmpty)
        XCTAssertNil(o.folderFor)
        XCTAssertEqual(o.notice, "Komprimieren von „kaputt.pdf“ fehlgeschlagen: "
                       + "\(PDFToolsError.unreadable.localizedDescription)\n"
                       + "Nicht kleiner geworden, daher nichts hinzugefügt: „\(input.lastPathComponent)“.")
    }

    // MARK: Generischer Auftrag

    private func waitUntilIdle(_ jobs: ConvertJobs) async throws {
        for _ in 0..<200 where !jobs.busy.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(jobs.busy.isEmpty)
    }

    func testRunMarksBusyBlocksDoubleStartAndAddsResult() async throws {
        let jobs = ConvertJobs(), shelf = Shelf()
        let a = makePDF("a.pdf"), b = makePDF("b.pdf"), first = makePDF("eins.pdf"), second = makePDF("zwei.pdf")
        jobs.run([a, b], shelf: shelf, failure: "x") {
            try await Task.sleep(for: .milliseconds(50))
            return .init(add: [first], notice: "Hinweis", folderFor: a)
        }
        XCTAssertEqual(jobs.busy, [a, b])
        jobs.run([b], shelf: shelf, failure: "x") { .init(add: [second]) }  // b läuft schon
        try await waitUntilIdle(jobs)
        XCTAssertEqual(shelf.items.map(\.url), [first])
        XCTAssertEqual(jobs.banners[shelf.id]?.text, "Hinweis")
        XCTAssertEqual(jobs.banners[shelf.id]?.folderFor, a)
    }

    func testRunShowsFailureBanner() async throws {
        let jobs = ConvertJobs(), shelf = Shelf()
        jobs.run([file("a.pdf")], shelf: shelf, failure: "Zusammenfügen fehlgeschlagen") { throw PDFToolsError.writeFailed }
        try await waitUntilIdle(jobs)
        XCTAssertTrue(shelf.items.isEmpty)
        XCTAssertEqual(jobs.banners[shelf.id]?.text,
                       "Zusammenfügen fehlgeschlagen: \(PDFToolsError.writeFailed.localizedDescription)")
        XCTAssertNil(jobs.banners[shelf.id]?.folderFor)
    }
}
