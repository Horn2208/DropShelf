import XCTest
import CoreText
import UniformTypeIdentifiers

/// Hostless: kopiert Systemschriften nur lesend in eigenen Temp-Ordner; `cacheDir` zeigt nie auf den echten Cache.
final class FontConverterTests: XCTestCase {
    private var tmp: URL!
    private var cache: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        tmp = fm.temporaryDirectory.appendingPathComponent("dropshelf-fonts-" + UUID().uuidString)
        cache = tmp.appendingPathComponent("cache")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: tmp)
    }

    // MARK: - Hilfsfunktionen

    private func copySystemTTF() throws -> URL {
        let preferred = [
            "/System/Library/Fonts/Supplemental/Arial.ttf",
            "/System/Library/Fonts/Monaco.ttf",
            "/System/Library/Fonts/Geneva.ttf",
            "/System/Library/Fonts/SFNS.ttf",
            "/System/Library/Fonts/Apple Symbols.ttf",
        ]
        var sourcePath = preferred.first { fm.fileExists(atPath: $0) }
        if sourcePath == nil {
            for dir in ["/System/Library/Fonts", "/System/Library/Fonts/Supplemental"] {
                if let files = try? fm.contentsOfDirectory(atPath: dir),
                   let found = files.sorted().first(where: { $0.lowercased().hasSuffix(".ttf") }) {
                    sourcePath = (dir as NSString).appendingPathComponent(found)
                    break
                }
            }
        }
        let path = try XCTUnwrap(sourcePath, "Keine System-.ttf-Schrift gefunden")
        let dst = tmp.appendingPathComponent("TestFont.ttf")
        try fm.copyItem(at: URL(fileURLWithPath: path), to: dst)
        return dst
    }

    private func copySystemTTC() throws -> URL? {
        let preferred = [
            "/System/Library/Fonts/Helvetica.ttc",
            "/System/Library/Fonts/Courier.ttc",
            "/System/Library/Fonts/Avenir.ttc",
        ]
        var sourcePath = preferred.first { fm.fileExists(atPath: $0) }
        if sourcePath == nil {
            for dir in ["/System/Library/Fonts", "/System/Library/Fonts/Supplemental"] {
                if let files = try? fm.contentsOfDirectory(atPath: dir),
                   let found = files.sorted().first(where: { $0.lowercased().hasSuffix(".ttc") }) {
                    sourcePath = (dir as NSString).appendingPathComponent(found)
                    break
                }
            }
        }
        guard let path = sourcePath else { return nil }
        let dst = tmp.appendingPathComponent("TestCollection.ttc")
        try fm.copyItem(at: URL(fileURLWithPath: path), to: dst)
        return dst
    }

    private func readUInt32BE(_ data: Data, at offset: Int) -> UInt32 {
        let i = data.startIndex + offset
        return (UInt32(data[i]) << 24) | (UInt32(data[i + 1]) << 16)
             | (UInt32(data[i + 2]) << 8) | UInt32(data[i + 3])
    }

    private func readUInt16BE(_ data: Data, at offset: Int) -> UInt16 {
        let i = data.startIndex + offset
        return (UInt16(data[i]) << 8) | UInt16(data[i + 1])
    }

    private func sfntTableTags(in data: Data) -> [UInt32] {
        guard data.count >= 12 else { return [] }
        let count = Int(readUInt16BE(data, at: 4))
        guard 12 + count * 16 <= data.count else { return [] }
        return (0..<count).map { readUInt32BE(data, at: 12 + $0 * 16) }
    }

    private func isValidSFNTMagic(_ magic: UInt32) -> Bool {
        magic == 0x0001_0000 || magic == 0x7472_7565 || magic == 0x4F54_544F
    }

    // MARK: - Tests

    func testConverterPairsExcludeOutlineConversion() {
        let pairs = FontConverter.converter.pairs
        XCTAssertTrue(pairs.contains(Conversion(from: FontConverter.ttf, to: FontConverter.woff)))
        XCTAssertTrue(pairs.contains(Conversion(from: FontConverter.woff, to: FontConverter.ttf)))
        XCTAssertTrue(pairs.contains(Conversion(from: FontConverter.otf, to: FontConverter.woff)))
        XCTAssertTrue(pairs.contains(Conversion(from: FontConverter.woff, to: FontConverter.otf)))
        XCTAssertTrue(pairs.contains(Conversion(from: FontConverter.ttc, to: FontConverter.ttf)))
        XCTAssertFalse(pairs.contains(Conversion(from: FontConverter.ttf, to: FontConverter.otf)))
        XCTAssertFalse(pairs.contains(Conversion(from: FontConverter.otf, to: FontConverter.ttf)))
        if FontConverter.supportsBrotli {
            XCTAssertTrue(pairs.contains(Conversion(from: FontConverter.ttf, to: FontConverter.woff2)))
            XCTAssertTrue(pairs.contains(Conversion(from: FontConverter.woff2, to: FontConverter.ttf)))
            XCTAssertTrue(pairs.contains(Conversion(from: FontConverter.woff, to: FontConverter.woff2)))
            XCTAssertTrue(pairs.contains(Conversion(from: FontConverter.woff2, to: FontConverter.woff)))
        }
    }

    func testTTFToWOFF1RoundTrip() async throws {
        let srcTTF = try copySystemTTF()
        let srcData = try Data(contentsOf: srcTTF)
        let srcTags = Set(sfntTableTags(in: srcData))
        XCTAssertGreaterThan(srcTags.count, 0)

        let woffURL = tmp.appendingPathComponent("TestFont.woff")
        try await FontConverter.converter.run(srcTTF, woffURL, ConvertOptions())
        let woffData = try Data(contentsOf: woffURL)
        XCTAssertEqual(readUInt32BE(woffData, at: 0), 0x774F_4646, "WOFF 1.0 Magic 'wOFF' erwartet")
        XCTAssertLessThan(woffData.count, srcData.count, "WOFF 1.0 sollte kleiner als unkomprimierte TTF sein")

        let roundTripTTF = tmp.appendingPathComponent("RoundTrip.ttf")
        try await FontConverter.converter.run(woffURL, roundTripTTF, ConvertOptions())
        let rtData = try Data(contentsOf: roundTripTTF)
        XCTAssertTrue(isValidSFNTMagic(readUInt32BE(rtData, at: 0)), "Ungültiges SFNT-Magic nach WOFF-Round-Trip")

        let rtTags = Set(sfntTableTags(in: rtData))
        XCTAssertEqual(rtTags.count, srcTags.count)
        XCTAssertEqual(rtTags, srcTags)

        let descriptors = CTFontManagerCreateFontDescriptorsFromURL(roundTripTTF as CFURL) as? [CTFontDescriptor]
        XCTAssertNotNil(descriptors)
        XCTAssertFalse(descriptors?.isEmpty ?? true, "CoreText sollte die rekonstruierte TTF laden können")
    }

    func testTTFToWOFF2RoundTrip() async throws {
        try XCTSkipUnless(FontConverter.supportsBrotli, "Brotli wird auf diesem System nicht unterstützt")

        let srcTTF = try copySystemTTF()
        let srcData = try Data(contentsOf: srcTTF)
        let srcTags = Set(sfntTableTags(in: srcData))

        let woff2URL = tmp.appendingPathComponent("TestFont.woff2")
        try await FontConverter.converter.run(srcTTF, woff2URL, ConvertOptions())
        let woff2Data = try Data(contentsOf: woff2URL)
        XCTAssertEqual(readUInt32BE(woff2Data, at: 0), 0x774F_4632, "WOFF 2.0 Magic 'wOF2' erwartet")
        XCTAssertLessThan(woff2Data.count, srcData.count, "WOFF 2.0 sollte kleiner als unkomprimierte TTF sein")

        let roundTripTTF = tmp.appendingPathComponent("RoundTripWoff2.ttf")
        try await FontConverter.converter.run(woff2URL, roundTripTTF, ConvertOptions())
        let rtData = try Data(contentsOf: roundTripTTF)
        XCTAssertTrue(isValidSFNTMagic(readUInt32BE(rtData, at: 0)), "Ungültiges SFNT-Magic nach WOFF2-Round-Trip")
        XCTAssertEqual(Set(sfntTableTags(in: rtData)), srcTags)

        let descriptors = CTFontManagerCreateFontDescriptorsFromURL(roundTripTTF as CFURL) as? [CTFontDescriptor]
        XCTAssertNotNil(descriptors)
        XCTAssertFalse(descriptors?.isEmpty ?? true, "CoreText sollte die aus WOFF2 rekonstruierte TTF laden können")
    }

    func testExtractTTC() throws {
        guard let srcTTC = try copySystemTTC() else {
            throw XCTSkip("Keine System-.ttc-Schrift gefunden")
        }

        let extracted = try FontConverter.extractTTC(srcTTC, mode: .besideOriginal, cacheDir: cache)
        XCTAssertGreaterThanOrEqual(extracted.count, 1)

        for fontURL in extracted {
            let ext = fontURL.pathExtension.lowercased()
            XCTAssertTrue(ext == "ttf" || ext == "otf", "Unerwartete Endung: \(ext)")
            let data = try Data(contentsOf: fontURL)
            XCTAssertGreaterThanOrEqual(data.count, 12)
            XCTAssertTrue(isValidSFNTMagic(readUInt32BE(data, at: 0)), "Ungültiges SFNT-Magic in \(fontURL.lastPathComponent)")
        }
    }

    func testConverterRegistryIntegration() async throws {
        let targets = ConverterRegistry.targets(for: FontConverter.ttf)
        XCTAssertTrue(targets.contains(FontConverter.woff))
        if FontConverter.supportsBrotli {
            XCTAssertTrue(targets.contains(FontConverter.woff2))
        }
        XCTAssertFalse(targets.contains(FontConverter.otf))

        let srcTTF = try copySystemTTF()
        let woff = try await ConverterRegistry.convert(srcTTF, to: FontConverter.woff, mode: .cache, cacheDir: cache)
        XCTAssertEqual(woff.pathExtension, "woff")
        let woffData = try Data(contentsOf: woff)
        XCTAssertEqual(readUInt32BE(woffData, at: 0), 0x774F_4646)
    }
}
