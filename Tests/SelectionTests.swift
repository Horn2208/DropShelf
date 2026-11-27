import AppKit
import XCTest

/// Reine Logik: Finder-Auswahl und Namensprüfung beim Inline-Umbenennen (ohne Dateien, ohne Shelf).
final class SelectionTests: XCTestCase {
    private let ids = (0..<5).map { _ in UUID() }
    private func sel() -> Selection { var s = Selection(); s.order = ids; return s }

    func testPlainClickSelectsOnlyOne() {
        var s = sel()
        s.click(ids[1]); s.click(ids[3])
        XCTAssertEqual(s.ids, [ids[3]])
    }

    func testCommandTogglesAndShiftSelectsRange() {
        var s = sel()
        s.click(ids[1])
        s.click(ids[3], command: true)
        XCTAssertEqual(s.ids, [ids[1], ids[3]])
        s.click(ids[1], command: true)
        XCTAssertEqual(s.ids, [ids[3]])
        s.click(ids[0], shift: true)  // Anker = 1 (zuletzt per Cmd geklickt) → 0…1
        XCTAssertEqual(s.ids, [ids[0], ids[1]])
        s.click(ids[4], shift: true)  // Anker bleibt: 1…4
        XCTAssertEqual(s.ids, Set(ids[1...4]))
        s.click(ids[3], command: true, shift: true)  // Cmd+Shift erweitert nur
        XCTAssertEqual(s.ids, Set(ids[1...4]))
    }

    func testShiftWithoutAnchorIsPlainClick() {
        var s = sel()
        s.click(ids[2], shift: true)
        XCTAssertEqual(s.ids, [ids[2]])
    }

    func testClearStepAndOrderChange() {
        var s = sel()
        s.step(1)
        XCTAssertEqual(s.ids, [ids[0]])
        s.step(-1)
        XCTAssertEqual(s.ids, [ids[0]])  // bleibt am Anfang
        s.click(ids[4]); s.step(1)
        XCTAssertEqual(s.ids, [ids[4]])
        s.click(ids[2], command: true)
        s.order = [ids[0], ids[2]]  // 4 entfernt → fällt aus Auswahl, Anker weg
        XCTAssertEqual(s.ids, [ids[2]])
        XCTAssertEqual(s.anchor, ids[2])
        s.clear()
        XCTAssertTrue(s.ids.isEmpty)
        XCTAssertNil(s.anchor)
    }

    // MARK: Umbenennen

    private func step(_ old: String, _ base: String, taken: Set<String> = []) -> RenameStep {
        Organize.renameStep(old, newBase: base) { taken.contains($0) }
    }

    func testRenameKeepsExtension() {
        let s = step("Lebenslauf.pdf", "CV 2026")
        XCTAssertEqual(s.new, "CV 2026.pdf"); XCTAssertNil(s.problem)
        XCTAssertEqual(step("archiv.tar.gz", "neu").new, "neu.gz")  // nur die letzte Endung ist fest (wie die Anzeige)
        XCTAssertEqual(step("README", "Liesmich").new, "Liesmich")
        XCTAssertEqual(step("a.txt", "  b  ").new, "b.txt")
    }

    func testRenameRejectsInvalid() {
        for base in ["", "   ", "a/b", "a:b"] {
            let s = step("a.txt", base)
            XCTAssertNotNil(s.problem, base)
            XCTAssertEqual(s.new, "a.txt", base)
        }
    }

    func testRenameCollision() {
        XCTAssertNotNil(step("a.txt", "b", taken: ["a.txt", "b.txt"]).problem)
        // Nur Groß-/Kleinschreibung oder unverändert: dieselbe Datei, keine Kollision.
        XCTAssertNil(step("a.txt", "A", taken: ["a.txt", "A.txt"]).problem)
        let same = step("a.txt", "a", taken: ["a.txt"])
        XCTAssertNil(same.problem); XCTAssertEqual(same.new, same.old)
    }
}

/// Aktionsleiste: teure Dienst-Prüfung nur bei neuer URL-Liste (sonst ruckelt jedes Neuzeichnen beim Hinzufügen).
@MainActor
final class ShelfActionCanPerformTests: XCTestCase {
    func testServiceCheckIsCachedPerURLList() {
        var calls = 0
        let check: (NSSharingService.Name, [URL]) -> Bool = { _, _ in calls += 1; return true }
        let a = [URL(fileURLWithPath: "/tmp/\(UUID()).txt")]
        let b = a + [URL(fileURLWithPath: "/tmp/\(UUID()).png")]
        XCTAssertTrue(ShelfAction.mail.canPerform(a, check: check))
        XCTAssertTrue(ShelfAction.mail.canPerform(a, check: check))
        XCTAssertEqual(calls, 1, "gleiche Liste: aus dem Speicher")
        XCTAssertTrue(ShelfAction.mail.canPerform(b, check: check))
        XCTAssertEqual(calls, 2, "neue Liste: neu prüfen")
        XCTAssertFalse(ShelfAction.mail.canPerform([], check: check))
        XCTAssertTrue(ShelfAction.zip.canPerform(a, check: check))
        XCTAssertEqual(calls, 2, "leere Liste und Aktionen ohne Dienst prüfen nie")
    }
}
