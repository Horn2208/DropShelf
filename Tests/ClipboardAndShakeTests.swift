import AppKit
import XCTest

/// ClipboardStore läuft hier auf eigenem Temp-Verzeichnis und eigenem Test-Pasteboard (nie `.general`, nie `.shared`).
@MainActor
final class ClipboardStoreTests: XCTestCase {
    private var tmp: URL!
    private var store: ClipboardStore!
    private var pb: NSPasteboard!

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("dropshelf-clip-test-" + UUID().uuidString)
        store = ClipboardStore(dir: tmp)
        pb = NSPasteboard(name: .init("DropShelf.unittest." + UUID().uuidString))
    }

    override func tearDown() async throws {
        pb.releaseGlobally()
        store.flush()  // storniert einen ausstehenden verzögerten Save
        store = nil
        try? FileManager.default.removeItem(at: tmp)
    }

    private func copy(_ t: String, _ extraTypes: [String] = []) {
        pb.clearContents(); pb.setString(t, forType: .string)
        extraTypes.forEach { pb.setData(Data([0]), forType: .init($0)) }
        store.ingest(pb, app: nil)
    }

    func testDedupeMovesToFront() {
        copy("a"); copy("b"); copy("a")
        XCTAssertEqual(store.entries.map(\.text), ["a", "b"])
    }

    func testDedupeKeepsPin() {
        copy("a"); copy("b")
        store.togglePin(store.entries[1].id)  // a
        copy("a")
        XCTAssertEqual(store.entries.count, 2)
        XCTAssertTrue(store.entries[0].pinned)
    }

    func testConcealedAndTransientAreSkipped() {
        copy("a")
        for t in ClipboardStore.skipTypes.sorted() { copy("geheim", [t]) }
        XCTAssertEqual(store.entries.map(\.text), ["a"])
    }

    func testEmptyAndWhitespaceIgnoredAndTrimmed() {
        copy(""); copy("   \n ")
        XCTAssertTrue(store.entries.isEmpty)
        copy("  x \n")
        XCTAssertEqual(store.entries.map(\.text), ["x"])
    }

    func testLinkDetection() {
        copy("https://example.com")
        XCTAssertEqual(store.entries.first?.kind, .url)
        copy("https://example.com mit text")
        XCTAssertEqual(store.entries.first?.kind, .text)
    }

    func testTrimKeepsPins() {
        copy("b")
        store.togglePin(store.entries[0].id)  // b
        store.limitOverride = 2
        copy("a")
        copy("c"); copy("d")
        XCTAssertEqual(store.entries.map(\.text), ["d", "b"])
    }

    func testTrimWithAllPinnedNeverRemovesAndTerminates() {
        copy("a"); copy("b"); copy("c")
        store.entries.forEach { store.togglePin($0.id) }
        store.limitOverride = 1
        store.trim()
        XCTAssertEqual(store.entries.count, 3)
    }

    func testClearKeepsPins() {
        copy("a"); copy("b"); copy("c")
        store.togglePin(store.entries[1].id)  // b
        store.clear(includingPinned: false)
        XCTAssertEqual(store.entries.map(\.text), ["b"])
        store.clear(includingPinned: true)
        XCTAssertTrue(store.entries.isEmpty)
    }

    // MARK: Passwortschutz

    private var indexFile: URL { tmp.appendingPathComponent("index.json") }

    private func captured(_ t: String) -> ClipboardStore.Captured {
        ClipboardStore.Captured(entry: ClipEntry(kind: .text, key: "t:" + t, text: t), png: nil)
    }

    func testLegacyMarkersAreSkipped() {
        for t in ["com.agilebits.onepassword", "de.petermaurer.TransientPasteboardType", "com.typeit4me.clipping", "Pasteboard generator type"] {
            copy("geheim", [t])
        }
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testDenylistedSourceIsSkipped() {
        pb.clearContents()
        pb.setString("geheim", forType: .string)
        pb.setString("com.apple.Passwords", forType: ClipboardStore.sourceType)
        store.ingest(pb, app: nil)
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testChangeCountRaceDiscardsRead() {
        pb.clearContents(); pb.setString("alt", forType: .string)
        let seen = pb.changeCount
        pb.clearContents(); pb.setString("neu", forType: .string)
        XCTAssertNil(ClipboardStore.capture(pb, images: false, expectedCount: seen))
        XCTAssertNotNil(ClipboardStore.capture(pb, images: false, expectedCount: pb.changeCount))
    }

    func testExpiryRemovesOldUnpinnedTextFromDisk() async throws {
        store.load()
        for _ in 0..<200 where !store.loaded { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(store.loaded)
        let t0 = Date()
        store.add(captured("alt"), app: nil, now: t0)
        store.add(captured("pin"), app: nil, now: t0)
        store.togglePin(store.entries[0].id)
        store.add(captured("neu"), app: nil, now: t0.addingTimeInterval(23 * 3600))
        store.flush()
        store.expire(now: t0.addingTimeInterval(24 * 3600 + 1))
        XCTAssertEqual(Set(store.entries.compactMap(\.text)), ["pin", "neu"])
        let disk: ([ClipEntry], Bool) = PersistedList.load(indexFile, keepBackup: false)
        XCTAssertEqual(Set(disk.0.compactMap(\.text)), ["pin", "neu"])
    }

    func testPauseBlocksCaptureAndContentStaysOutAfterwards() {
        let t0 = Date()
        store.poll(pb, now: t0)
        store.pause(now: t0)
        pb.clearContents(); pb.setString("geheim", forType: .string)
        store.poll(pb, now: t0.addingTimeInterval(10))
        pb.clearContents(); pb.setString("geheim2", forType: .string)  // direkt vor Pausenende, ohne Poll dazwischen
        store.poll(pb, now: t0.addingTimeInterval(ClipboardStore.pauseDuration))
        XCTAssertNil(store.pausedUntil)
        store.poll(pb, now: t0.addingTimeInterval(ClipboardStore.pauseDuration + 1))
        XCTAssertTrue(store.entries.isEmpty)
        pb.clearContents(); pb.setString("danach", forType: .string)
        store.poll(pb, now: t0.addingTimeInterval(ClipboardStore.pauseDuration + 2))
        XCTAssertEqual(store.entries.map(\.text), ["danach"])
    }

    func testEndPauseDoesNotCaptureContentCopiedDuringPause() {
        store.poll(pb)
        store.pause()
        pb.clearContents(); pb.setString("geheim", forType: .string)
        store.endPause(pb)
        store.poll(pb)
        XCTAssertNil(store.pausedUntil)
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testClearWhileBlockedDeletesFileAndRestoresSaving() async throws {
        try Data("geheim, kein JSON".utf8).write(to: indexFile)
        let orphan = tmp.appendingPathComponent("images/alt.png")
        try Data([1]).write(to: orphan)
        store.load()
        for _ in 0..<200 where !store.unreadable { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(store.unreadable)
        store.flush()
        XCTAssertEqual(try Data(contentsOf: indexFile), Data("geheim, kein JSON".utf8), "blockiert: nicht überschreiben")

        store.clear(includingPinned: false)
        XCTAssertFalse(store.unreadable)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertFalse(String(decoding: try Data(contentsOf: indexFile), as: UTF8.self).contains("geheim"))

        copy("neu")
        store.flush()
        let disk: ([ClipEntry], Bool) = PersistedList.load(indexFile, keepBackup: false)
        XCTAssertEqual(disk.0.map(\.text), ["neu"])
    }

    func testStorageIsExcludedFromBackup() throws {
        XCTAssertEqual(try tmp.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    }
}

@MainActor
final class ShakeDetectorTests: XCTestCase {
    func testReversalsPortedAsserts() {
        XCTAssertEqual(ShakeDetector.reversals([0, 50, 0, 50, 0, 50], minSegment: 40), 4)
        XCTAssertEqual(ShakeDetector.reversals([0, 10, 0, 10, 0, 10], minSegment: 40), 0)
        XCTAssertEqual(ShakeDetector.reversals([0, 20, 60, 100, 200], minSegment: 40), 0)
        XCTAssertEqual(ShakeDetector.reversals([0, 50, 100, 40, 90, 20], minSegment: 40), 3)
        XCTAssertEqual(ShakeDetector.minSegment(sensitivity: 0.5), 40)
    }

    func testReversalsEdgeCases() {
        XCTAssertEqual(ShakeDetector.reversals([], minSegment: 40), 0)
        XCTAssertEqual(ShakeDetector.reversals([5], minSegment: 40), 0)
        XCTAssertEqual(ShakeDetector.reversals([0, 0, 0, 0], minSegment: 40), 0)
        XCTAssertEqual(ShakeDetector.reversals([0, 40, 0], minSegment: 40), 1, "genau minSegment zählt")
        XCTAssertEqual(ShakeDetector.reversals([0, 39, 0], minSegment: 40), 0)
        XCTAssertEqual(ShakeDetector.reversals([100, 50, 100, 50], minSegment: 40), 2, "Start nach links")
    }

    func testMinSegmentClamps() {
        XCTAssertEqual(ShakeDetector.minSegment(sensitivity: 0), 60)
        XCTAssertEqual(ShakeDetector.minSegment(sensitivity: 1), 20)
        XCTAssertEqual(ShakeDetector.minSegment(sensitivity: -5), 60)
        XCTAssertEqual(ShakeDetector.minSegment(sensitivity: 9), 20)
    }
}
