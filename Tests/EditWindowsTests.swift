import XCTest
import AppKit
import SwiftUI
import PDFKit
import CoreText
import AVFoundation

private final class Log: @unchecked Sendable { var entries: [String] = [] }

private struct Probe: NSViewRepresentable {
    let log: Log
    func makeCoordinator() -> Log { log }
    func makeNSView(context: Context) -> NSView { context.coordinator.entries.append("make"); return NSView() }
    func updateNSView(_ v: NSView, context: Context) {}
    static func dismantleNSView(_ v: NSView, coordinator: Log) { coordinator.entries.append("dismantle") }
}

/// Hostless: Modell, Abläufe und View-Abbau ohne Fenster; nur eigener Temp-Ordner, `cacheDir` auf Temp.
@MainActor
final class EditWindowsTests: XCTestCase {
    private var tmp: URL!
    private var cache: URL!
    private let fm = FileManager.default

    override func setUp() async throws {
        tmp = fm.temporaryDirectory.appendingPathComponent("dropshelf-editwindows-" + UUID().uuidString)
        cache = tmp.appendingPathComponent("cache")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() async throws { try? fm.removeItem(at: tmp) }

    private func file(_ name: String) -> URL { tmp.appendingPathComponent(name) }

    private func makePDF(_ name: String, pages: [String]) -> URL {
        let url = file(name)
        var box = CGRect(x: 0, y: 0, width: 300, height: 200)
        let ctx = CGContext(url as CFURL, mediaBox: &box, nil)!
        for text in pages {
            ctx.beginPDFPage(nil)
            ctx.textPosition = CGPoint(x: 20, y: 100)
            CTLineDraw(CTLineCreateWithAttributedString(
                NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 24)])), ctx)
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return url
    }

    private func text(_ p: PDFPage?) -> String { (p?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
    private func texts(_ url: URL) throws -> [String] {
        let d = try XCTUnwrap(PDFDocument(url: url))
        return (0..<d.pageCount).map { text(d.page(at: $0)) }
    }

    // MARK: Menü

    func testWindowItemsNeedExactlyOneMatchingFile() {
        let pdf = file("a.pdf"), pdf2 = file("b.pdf"), mov = file("c.MOV"), mp3 = file("d.mp3"), txt = file("e.txt")
        XCTAssertEqual(EditMenu.plan([pdf]).pages, pdf)
        XCTAssertNil(EditMenu.plan([pdf]).trim)
        XCTAssertEqual(EditMenu.plan([txt, pdf]).pages, pdf)
        XCTAssertNil(EditMenu.plan([pdf, pdf2]).pages)
        XCTAssertEqual(EditMenu.plan([mov, pdf, txt]).trim, mov)
        XCTAssertNil(EditMenu.plan([mov, mp3]).trim)
        for ext in ["mov", "mp4", "m4v", "mp3", "m4a", "wav", "aif", "aiff", "caf"] {
            XCTAssertEqual(EditMenu.plan([file("x." + ext)]).trim, file("x." + ext), ext)
        }
        for ext in ["avi", "mkv", "flac", "ogg", "png", "pdf", ""] {
            XCTAssertNil(EditMenu.plan([file("x." + ext)]).trim, ext)
        }
    }

    func testWindowItemsInSubmenu() {
        let shelf = Shelf()
        func titles(_ urls: [URL]) -> [String] { EditMenu.menuItem(for: urls, shelf: shelf)?.submenu?.items.map(\.title) ?? [] }
        XCTAssertEqual(titles([file("a.pdf")]), ["Komprimieren", "Seiten verwalten …"])
        XCTAssertEqual(titles([file("a.m4a")]), ["Kürzen …"])
        XCTAssertEqual(titles([file("a.pdf"), file("b.mp4")]), ["Komprimieren", "Seiten verwalten …", "Kürzen …"])
        XCTAssertEqual(titles([file("a.mp4"), file("b.mp4")]), [])
    }

    func testNoStrongWarningForBusyFiles() async throws {
        let jobs = ConvertJobs(), shelf = Shelf(), a = file("a.pdf")
        var asked = 0
        jobs.run([a], shelf: shelf, failure: "x") { try await Task.sleep(for: .milliseconds(80)); return .init() }
        EditMenu.compress([a], level: .high, shelf: shelf, jobs: jobs) { _ in asked += 1; return false }
        XCTAssertEqual(asked, 0)
        for _ in 0..<200 where !jobs.busy.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        EditMenu.compress([a], level: .high, shelf: shelf, jobs: jobs) { _ in asked += 1; return false }
        XCTAssertEqual(asked, 1)
        XCTAssertTrue(jobs.busy.isEmpty, "Abbrechen startet nichts")
    }

    func testRunReportsWhetherItStarted() async throws {
        let jobs = ConvertJobs(), shelf = Shelf(), a = file("a.pdf")
        XCTAssertTrue(jobs.run([a], shelf: shelf, failure: "x") { .init() })
        XCTAssertFalse(jobs.run([a], shelf: shelf, failure: "x") { .init() })
        for _ in 0..<200 where !jobs.busy.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
    }

    func testMergeJobFolderButtonSkipsBrokenFirstFile() throws {
        let locked = file("gesperrt")
        try fm.createDirectory(at: locked, withIntermediateDirectories: true)
        let a = makePDF("gesperrt/a.pdf", pages: ["A"]), b = makePDF("gesperrt/b.pdf", pages: ["B"])
        let broken = file("0.pdf"); try Data("kein pdf".utf8).write(to: broken)
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        let o = try EditMenu.mergeJob([broken, a, b], cacheDir: cache)
        XCTAssertEqual(o.folderFor, a)
        XCTAssertEqual(o.add.first?.lastPathComponent, "a (zusammengefügt).pdf")
    }

    // MARK: Seiten-Modell

    private func model(_ pages: [String] = ["S1", "S2", "S3", "S4"]) throws -> PDFPagesModel {
        try PDFPagesModel(url: makePDF("m-\(UUID().uuidString).pdf", pages: pages))
    }

    private func order(_ m: PDFPagesModel) -> [String] { m.pages.indices.map { text(m.page(at: $0)) } }
    private func select(_ m: PDFPagesModel, _ indices: [Int]) {
        m.selection.clear()
        for i in indices { m.selection.click(m.pages[i].id, command: true) }
    }

    func testModelRejectsUnreadableAndLocked() throws {
        let broken = file("kaputt.pdf"); try Data("kein pdf".utf8).write(to: broken)
        let locked = file("zu.pdf")
        XCTAssertTrue(try XCTUnwrap(PDFDocument(url: makePDF("q.pdf", pages: ["A"])))
            .write(to: locked, withOptions: [.userPasswordOption: "geheim", .ownerPasswordOption: "chef"]))
        for url in [broken, locked, file("fehlt.pdf")] {
            XCTAssertThrowsError(try PDFPagesModel(url: url), url.lastPathComponent) {
                XCTAssertEqual(($0 as? PDFToolsError)?.errorDescription, PDFToolsError.unreadable.errorDescription)
            }
        }
    }

    func testModelSelection() throws {
        let m = try model()
        XCTAssertEqual(m.selected, [])
        m.selection.click(m.pages[2].id)
        m.selection.click(m.pages[0].id, command: true)
        XCTAssertEqual(m.selected, [0, 2])
        m.selection.click(m.pages[1].id)
        m.selection.click(m.pages[3].id, shift: true)
        XCTAssertEqual(m.selected, [1, 2, 3])
    }

    func testModelMoveKeepsRelativeOrderAndStopsAtEdges() throws {
        let m = try model()
        XCTAssertFalse(m.canMove(-1)); XCTAssertFalse(m.canMove(1))
        select(m, [1, 2])
        m.move(-1)
        XCTAssertEqual(order(m), ["S2", "S3", "S1", "S4"])
        XCTAssertEqual(m.selected, [0, 1])
        XCTAssertFalse(m.canMove(-1))
        m.move(-1)
        XCTAssertEqual(order(m), ["S2", "S3", "S1", "S4"])
        m.move(1); m.move(1)
        XCTAssertEqual(order(m), ["S1", "S4", "S2", "S3"])
        XCTAssertFalse(m.canMove(1))

        let g = try model()
        select(g, [0, 2])  // erste steht schon am Rand, die andere rückt nach
        g.move(-1)
        XCTAssertEqual(order(g), ["S1", "S3", "S2", "S4"])
        XCTAssertEqual(g.selected, [0, 1])
        // Auswahlbereich folgt der neuen Reihenfolge.
        g.selection.click(g.pages[0].id); g.selection.click(g.pages[2].id, shift: true)
        XCTAssertEqual(g.selected, [0, 1, 2])
    }

    func testModelDeleteNeverRemovesAllPages() throws {
        let m = try model(["A", "B", "C"])
        XCTAssertFalse(m.canDelete)
        select(m, [0, 1, 2])
        XCTAssertFalse(m.canDelete)
        m.delete()
        XCTAssertEqual(order(m), ["A", "B", "C"])
        select(m, [0, 2])
        XCTAssertTrue(m.canDelete)
        m.delete()
        XCTAssertEqual(order(m), ["B"])
        XCTAssertEqual(m.selected, [])
        XCTAssertTrue(m.isDirty)
        select(m, [0])
        XCTAssertFalse(m.canDelete)
    }

    func testModelDirtyState() throws {
        let m = try model()
        XCTAssertFalse(m.isDirty)
        select(m, [1])
        XCTAssertFalse(m.isDirty, "Auswahl allein ändert nichts")
        m.rotate(by: 90)
        XCTAssertTrue(m.isDirty)
        XCTAssertEqual(m.page(at: 1)?.rotation, 90)
        XCTAssertEqual(m.pages[1].rotation, 90)
        m.rotate(by: -90)
        XCTAssertFalse(m.isDirty)
        m.move(1); XCTAssertTrue(m.isDirty)
        m.move(-1); XCTAssertFalse(m.isDirty)
    }

    func testModelSaveAndExtract() throws {
        let m = try model()
        let before = try Data(contentsOf: m.source)
        select(m, [3, 1])
        m.rotate(by: 90)
        let x = try m.extract(cacheDir: cache)
        XCTAssertTrue(x.url.lastPathComponent.hasSuffix("(Auszug).pdf"))
        XCTAssertEqual(try texts(x.url).count, 2)
        XCTAssertEqual(PDFDocument(url: x.url)?.page(at: 0)?.rotation, 90)
        XCTAssertTrue(m.isDirty, "Extrahieren speichert die Änderungen nicht")
        XCTAssertEqual(order(m), ["S1", "S2", "S3", "S4"])

        let s = try m.save(cacheDir: cache)
        XCTAssertTrue(s.url.lastPathComponent.hasSuffix("(bearbeitet).pdf"))
        XCTAssertFalse(m.isDirty)
        XCTAssertEqual(PDFDocument(url: s.url)?.page(at: 1)?.rotation, 90)
        XCTAssertEqual(try Data(contentsOf: m.source), before, "Original bleibt unverändert")

        m.selection.clear()
        XCTAssertThrowsError(try m.extract(cacheDir: cache), "ohne Auswahl")
    }

    // MARK: Interne Links

    /// S1 → S3, S1 → S4 (Aktion), S1 → Web, S4 → S1; frisch von der Platte, Anmerkungen noch nicht geladen.
    private func makeLinkedPDF() throws -> URL {
        let base = try XCTUnwrap(PDFDocument(url: makePDF("basis-\(UUID().uuidString).pdf", pages: ["S1", "S2", "S3", "S4"])))
        let d = PDFDocument()
        for i in 0..<base.pageCount { d.insert(try XCTUnwrap(base.page(at: i)), at: d.pageCount) }
        func link(_ from: Int, _ x: CGFloat) throws -> PDFAnnotation {
            let l = PDFAnnotation(bounds: CGRect(x: x, y: 10, width: 40, height: 20), forType: .link, withProperties: nil)
            try XCTUnwrap(d.page(at: from)).addAnnotation(l)
            return l
        }
        func dest(_ i: Int) throws -> PDFDestination { PDFDestination(page: try XCTUnwrap(d.page(at: i)), at: .zero) }
        try link(0, 10).destination = dest(2)
        try link(0, 60).action = PDFActionGoTo(destination: dest(3))
        try link(0, 110).action = PDFActionURL(url: URL(string: "https://example.com")!)
        try link(3, 10).destination = dest(0)
        let url = file("links-\(UUID().uuidString).pdf")
        XCTAssertTrue(d.write(to: url))
        return url
    }

    /// Je Seite (am Text erkannt) die Texte der Zielseiten ihrer internen Links.
    private func links(_ url: URL) throws -> [String: [String]] {
        let d = try XCTUnwrap(PDFDocument(url: url))
        var r: [String: [String]] = [:]
        for i in 0..<d.pageCount {
            let p = try XCTUnwrap(d.page(at: i))
            r[text(p)] = p.annotations.filter { $0.type == "Link" }
                .compactMap { (($0.action as? PDFActionGoTo)?.destination ?? $0.destination)?.page }
                .map { text($0) }.sorted()
        }
        return r
    }

    private func webLinks(_ url: URL) throws -> Int {
        let d = try XCTUnwrap(PDFDocument(url: url))
        return (0..<d.pageCount).flatMap { d.page(at: $0)!.annotations }.filter { $0.action is PDFActionURL }.count
    }

    func testLinkFixture() throws {
        let src = try makeLinkedPDF()
        XCTAssertEqual(try links(src), ["S1": ["S3", "S4"], "S2": [], "S3": [], "S4": ["S1"]])
        XCTAssertEqual(try webLinks(src), 1)
    }

    func testLinksSurviveMoveAndRotate() throws {
        let m = try PDFPagesModel(url: makeLinkedPDF())
        select(m, [2, 3])
        m.move(-1); m.move(-1)
        m.rotate(by: 90)
        let out = try m.save(cacheDir: cache).url
        XCTAssertEqual(try texts(out), ["S3", "S4", "S1", "S2"])
        XCTAssertEqual(try links(out), ["S1": ["S3", "S4"], "S2": [], "S3": [], "S4": ["S1"]])
        XCTAssertEqual(try webLinks(out), 1)
    }

    func testLinksAfterDeletingPages() throws {
        let m = try PDFPagesModel(url: makeLinkedPDF())
        select(m, [1])
        m.delete()
        XCTAssertEqual(try links(m.save(cacheDir: cache).url), ["S1": ["S3", "S4"], "S3": [], "S4": ["S1"]])
        // Gelöschtes Linkziel: der Link darf nicht auf eine andere Seite zeigen.
        select(m, [1])
        m.delete()
        let out = try m.save(cacheDir: cache).url
        XCTAssertEqual(try links(out), ["S1": ["S4"], "S4": ["S1"]])
        XCTAssertEqual(try webLinks(out), 1)
    }

    func testLinksInExtract() throws {
        let m = try PDFPagesModel(url: makeLinkedPDF())
        select(m, [1]); m.move(1); m.move(1)  // S1, S3, S4, S2
        select(m, [0, 2])                      // Auszug S1, S4
        let out = try m.extract(cacheDir: cache).url
        XCTAssertEqual(try texts(out), ["S1", "S4"])
        XCTAssertEqual(try links(out), ["S1": ["S4"], "S4": ["S1"]])
        XCTAssertEqual(try webLinks(out), 1)
        // Das Dokument im Fenster bleibt dabei unversehrt.
        XCTAssertEqual(try links(m.save(cacheDir: cache).url), ["S1": ["S3", "S4"], "S2": [], "S3": [], "S4": ["S1"]])
    }

    // MARK: Kürzen

    private func session(_ log: Log) -> TrimSession {
        TrimSession(start: { log.entries.append("start \($0.duration.seconds)") },
                    report: { log.entries.append("report " + $0) }, close: { log.entries.append("close") })
    }

    func testTrimSessionClosesOnce() {
        let r = CMTimeRange(start: .zero, duration: CMTime(seconds: 1, preferredTimescale: 600))
        let a = Log(), s = session(a)
        s.trim(r); s.cancel(); s.fail("zu spät"); s.trim(r)
        XCTAssertEqual(a.entries, ["start 1.0", "close"])
        let b = Log(), c = session(b)
        c.cancel(); c.cancel(); c.trim(r)
        XCTAssertEqual(b.entries, ["close"])
        let d = Log(), e = session(d)
        e.fail("kaputt"); e.cancel()
        XCTAssertEqual(d.entries, ["report kaputt", "close"])
    }

    /// WAV/AIFF/CAF (PCM) oder M4A (AAC), 3 s.
    private func tone(_ ext: String) throws -> URL {
        let url = file("Ton." + ext)
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        let n = AVAudioFrameCount(44100 * 3)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n)!
        buf.frameLength = n
        for c in 0..<2 { for i in 0..<Int(n) { buf.floatChannelData![c][i] = 0.25 * Float(sin(2 * .pi * 440 * Double(i) / 44100)) } }
        var settings: [String: Any] = [AVSampleRateKey: 44100, AVNumberOfChannelsKey: 2]
        if ext == "m4a" {
            settings[AVFormatIDKey] = kAudioFormatMPEG4AAC
        } else {
            settings[AVFormatIDKey] = kAudioFormatLinearPCM
            settings[AVLinearPCMBitDepthKey] = 16
            settings[AVLinearPCMIsFloatKey] = false
            settings[AVLinearPCMIsBigEndianKey] = ext.hasPrefix("aif")
        }
        try autoreleasepool {  // Datei wird beim Freigeben abgeschlossen
            try AVAudioFile(forWriting: url, settings: settings).write(from: buf)
        }
        return url
    }

    /// 2-s-Clip, 64x64, 10 fps.
    private func clip(_ ext: String, _ type: AVFileType) async throws -> URL {
        let url = file("Clip." + ext)
        let w = try AVAssetWriter(outputURL: url, fileType: type)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64,
            AVVideoCompressionPropertiesKey: [AVVideoMaxKeyFrameIntervalKey: 1]])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64])
        w.add(input)
        XCTAssertTrue(w.startWriting())
        w.startSession(atSourceTime: .zero)
        for i in 0..<20 {
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &pb)
            let b = try XCTUnwrap(pb)
            CVPixelBufferLockBaseAddress(b, [])
            memset(CVPixelBufferGetBaseAddress(b), 0x80, CVPixelBufferGetBytesPerRow(b) * 64)
            CVPixelBufferUnlockBaseAddress(b, [])
            for _ in 0..<1000 where !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertTrue(adaptor.append(b, withPresentationTime: CMTime(value: Int64(i), timescale: 10)))
        }
        input.markAsFinished()
        await w.finishWriting()
        XCTAssertEqual(w.status, .completed, "\(String(describing: w.error))")
        return url
    }

    /// Beleg für jede Endung, bei der „Kürzen …“ erscheint: abspielbar und über den Auftrag wirklich schneidbar.
    func testEveryOfferedExtensionCanBeTrimmed() async throws {
        let mp3Source = try tone("caf")
        var sources = [mp3Source, try tone("wav"), try tone("aif"), try tone("aiff"), try tone("m4a")]
        sources.append(try await ConverterRegistry.convert(mp3Source, to: .mp3, mode: .cache, cacheDir: file("quellen")))
        sources.append(try await clip("mov", .mov))
        sources.append(try await clip("mp4", .mp4))
        sources.append(try await clip("m4v", .m4v))
        XCTAssertEqual(Set(sources.map(\.pathExtension)), EditMenu.trimExtensions)
        let range = CMTimeRange(start: CMTime(seconds: 0.5, preferredTimescale: 600),
                                end: CMTime(seconds: 1.5, preferredTimescale: 600))
        let c = cache!
        for src in sources {
            let ext = src.pathExtension
            let playable = try await AVURLAsset(url: src).load(.isPlayable)
            XCTAssertTrue(playable, ext)
            let before = try Data(contentsOf: src)
            let o = try await withTimeout { try await EditMenu.trimJob(src, range: range, cacheDir: c) }
            let out = try XCTUnwrap(o.add.first, ext)
            XCTAssertNotEqual(out, src, ext)
            XCTAssertTrue(out.lastPathComponent.contains("gekürzt"), ext)
            XCTAssertNil(o.notice, ext)
            XCTAssertNil(o.folderFor, ext)
            let seconds = try await AVURLAsset(url: out).load(.duration).seconds
            XCTAssertEqual(seconds, 1.0, accuracy: 0.15, ext)
            XCTAssertEqual(try Data(contentsOf: src), before, "\(ext): Original verändert")
        }
    }

    func testEmptyTrimRangeShowsBanner() async throws {
        let jobs = ConvertJobs(), shelf = Shelf(), src = try tone("wav"), c = cache!
        let empty = CMTimeRange(start: CMTime(seconds: 2, preferredTimescale: 600), duration: .zero)
        jobs.run([src], shelf: shelf, failure: "Kürzen fehlgeschlagen") { try await EditMenu.trimJob(src, range: empty, cacheDir: c) }
        for _ in 0..<500 where !jobs.busy.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(jobs.banners[shelf.id]?.text, "Kürzen fehlgeschlagen: Der gewählte Bereich ist leer.")
        XCTAssertTrue(shelf.items.isEmpty)
    }

    // MARK: View-Abbau und TrimView (ohne Fenster)

    private func host<V: View>(_ v: V) -> NSHostingController<AnyView> {
        let h = NSHostingController(rootView: AnyView(v))
        h.view.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        h.view.layoutSubtreeIfNeeded()
        return h
    }

    func testDismantleReallyRemovesViews() async throws {
        let log = Log(), h = host(Probe(log: log))
        for _ in 0..<100 where log.entries.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(log.entries, ["make"])
        EditWindow.dismantle(h)
        for _ in 0..<100 where log.entries.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(log.entries, ["make", "dismantle"])
    }

    private func trimView(_ url: URL, _ log: Log) -> TrimView {
        TrimView(url: url, onTrim: { _ in log.entries.append("trim") }, onCancel: { log.entries.append("cancel") },
                 onError: { log.entries.append($0) })
    }

    func testTrimViewReportsUnplayableFile() async throws {
        let broken = file("kaputt.mp4"); try Data("kein video".utf8).write(to: broken)
        let log = Log(), h = host(trimView(broken, log))
        for _ in 0..<500 where log.entries.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(log.entries, ["„kaputt.mp4“ kann nicht abgespielt werden. Die Datei ist beschädigt oder das Format wird nicht unterstützt."])
        EditWindow.dismantle(h)
    }

    func testTrimViewStaysSilentWhenDismantled() async throws {
        let log = Log(), h = host(trimView(try tone("wav"), log))
        try await Task.sleep(for: .milliseconds(300))  // wartet auf ein Fenster, das es hier nie gibt
        EditWindow.dismantle(h)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(log.entries, [])
    }
}
