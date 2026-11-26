import XCTest
import UniformTypeIdentifiers

final class ConvertMenuTests: XCTestCase {
    private func split(_ s: String) -> [String] { let p = ConvertMenu.split(s); return [p.base, p.ext] }

    func testSplit() {
        XCTAssertEqual(split("PI1_Tut_10.pdf"), ["PI1_Tut_10", ".pdf"])
        XCTAssertEqual(split("Archiv.tar.gz"), ["Archiv.tar", ".gz"])
        XCTAssertEqual(split(".bashrc"), [".bashrc", ""])
        XCTAssertEqual(split(".config.json"), [".config", ".json"])
        XCTAssertEqual(split("README"), ["README", ""])
        XCTAssertEqual(split("Punkt."), ["Punkt.", ""])
    }

    func testPDFMenuModel() {
        let to: [UTType] = [.png, .jpeg] + PDFConverter.writableText
        let m = ConvertMenu.targets(from: .pdf, to: to) { _ in [] }
        XCTAssertEqual(m.map(\.title), m.map(\.title).sorted())
        XCTAssertNil(m.first { $0.type == .png }?.warning)
        XCTAssertEqual(m.first { $0.type == .plainText }?.warning, PDFConverter.textExtractionWarning)
        XCTAssertEqual(m.first { $0.type == .plainText }?.title, "TXT")
        XCTAssertTrue(m.allSatisfy { $0.presets.isEmpty })
    }

    func testAudioPresetsBecomeSubmenuWithDefaultFirst() {
        let m = ConvertMenu.targets(from: .wav, to: [AudioConverter.m4a, .mp3]) {
            $0 == AudioConverter.m4a ? ["aac", "alac", "heaac"] : []
        }
        XCTAssertEqual(m.map(\.title), ["M4A", "MP3"])
        XCTAssertEqual(m[0].presets.map(\.title), ["AAC", "ALAC", "HE-AAC"])
        XCTAssertEqual(m[0].presets.first?.id, "aac")
        XCTAssertNil(m[0].warning)
    }

    func testSectionsSplitWarnedTargets() {
        let m = ConvertMenu.targets(from: .pdf, to: [.png, .plainText, .rtf]) { _ in [] }
        let s = ConvertMenu.sections(m)
        XCTAssertEqual(s.map(\.title), ["Umwandeln in", PDFConverter.textExtractionWarning])
        XCTAssertEqual(s.map(\.warned), [false, true])
        XCTAssertEqual(s[0].targets.map(\.title), ["PNG"])
        XCTAssertEqual(s[1].targets.map(\.title), ["RTF", "TXT"])
        XCTAssertTrue(ConvertMenu.sections([]).isEmpty)
    }

    func testConvertPrefsDecision() {
        let name = "ConvertPrefsTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        defer { d.removePersistentDomain(forName: name) }
        XCTAssertNil(ConvertPrefs.preset(d))  // Standard: fragen
        XCTAssertEqual(ConvertPrefs.resolve(.add, suppress: false, d), .add)
        XCTAssertNil(ConvertPrefs.preset(d))  // ohne Häkchen wird nichts gespeichert
        XCTAssertNil(ConvertPrefs.resolve(.cancel, suppress: true, d))
        XCTAssertNil(ConvertPrefs.preset(d))  // Abbrechen speichert nie
        XCTAssertEqual(ConvertPrefs.resolve(.add, suppress: true, d), .add)
        XCTAssertEqual(ConvertPrefs.preset(d), .add)
        d.set(true, forKey: ConvertPrefs.replaceKey)
        XCTAssertEqual(ConvertPrefs.preset(d), .replace)
        d.set(true, forKey: ConvertPrefs.askKey)
        XCTAssertNil(ConvertPrefs.preset(d))
        d.removeObject(forKey: ConvertPrefs.replaceKey)
        d.set(false, forKey: ConvertPrefs.askKey)
        XCTAssertEqual(ConvertPrefs.preset(d), .replace)  // Ersetzen ist Standard
    }

    func testNoTargetsGivesEmptyMenu() {
        XCTAssertTrue(ConverterRegistry.targets(for: .zip).isEmpty)
        XCTAssertTrue(ConvertMenu.targets(from: .zip, to: []) { _ in ["x"] }.isEmpty)
    }
}
