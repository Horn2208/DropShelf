import Foundation
import Compression
import UniformTypeIdentifiers

/// Reine Swift-Konvertierung für Schrift-Container: SFNT (TTF/OTF) ↔ WOFF 1.0 / WOFF 2.0 sowie TTC-Extraktion.
enum FontConverter {
    static let ttf = UTType("public.truetype-ttf-font") ?? UTType(filenameExtension: "ttf")!
    static let otf = UTType("public.opentype-font") ?? UTType(filenameExtension: "otf")!
    static let ttc = UTType("public.truetype-collection-font") ?? UTType(filenameExtension: "ttc")!
    static let woff = UTType("org.w3.woff") ?? UTType(filenameExtension: "woff")!
    static let woff2 = UTType("org.w3.woff2") ?? UTType(filenameExtension: "woff2")!

    /// Prüft zur Laufzeit, ob `COMPRESSION_BROTLI` auf diesem System sauber kodiert und dekodiert.
    static var supportsBrotli: Bool { _supportsBrotli }
    private static let _supportsBrotli: Bool = {
        let probe = Data("DropShelf WOFF2 Brotli probe 0123456789".utf8)
        guard let encoded = brotliCompress(probe),
              let decoded = brotliDecompress(encoded, expectedSize: probe.count)
        else { return false }
        return decoded == probe
    }()

    static var readable: [UTType] {
        [ttf, otf, ttc, woff] + (supportsBrotli ? [woff2] : [])
    }

    static var writable: [UTType] {
        [ttf, otf, woff] + (supportsBrotli ? [woff2] : [])
    }

    static var converter: Converter {
        var pairs: Set<Conversion> = [
            Conversion(from: ttf, to: woff),
            Conversion(from: otf, to: woff),
            Conversion(from: woff, to: ttf),
            Conversion(from: woff, to: otf),
            Conversion(from: ttc, to: ttf),
        ]
        if supportsBrotli {
            pairs.formUnion([
                Conversion(from: ttf, to: woff2),
                Conversion(from: otf, to: woff2),
                Conversion(from: woff, to: woff2),
                Conversion(from: woff2, to: ttf),
                Conversion(from: woff2, to: otf),
                Conversion(from: woff2, to: woff),
            ])
        }
        return Converter(id: "font", pairs: pairs) { src, dst, _ in
            try convert(src, dst)
        }
    }

    /// Extrahiert alle Einzelschriften einer TrueType Collection (`.ttc`) in einen Ordner „<Name> (Schriften)“.
    @discardableResult
    static func extractTTC(_ url: URL, mode: OutputMode = .besideOriginal,
                           cacheDir: URL = Shelf.cacheDir) throws -> [URL] {
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw ConvertError.unreadable }
        let fonts = try parseTTC(data)
        guard !fonts.isEmpty else { throw ConvertError.unreadable }

        let fm = FileManager.default
        let tmpFolder = fm.temporaryDirectory.appendingPathComponent("dropshelf-ttc-" + UUID().uuidString)
        try fm.createDirectory(at: tmpFolder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmpFolder) }

        for (index, font) in fonts.enumerated() {
            let ext = font.flavor == sfntOTTO ? "otf" : "ttf"
            let fileName = String(format: "Schrift-%03d.%@", index + 1, ext)
            let sfntData = try buildSFNT(font)
            try sfntData.write(to: tmpFolder.appendingPathComponent(fileName))
        }

        let placedDir = try FileOutput.place(tmpFolder, for: url, suffix: "Schriften", ext: "", mode: mode, cacheDir: cacheDir)
        let contents = try fm.contentsOfDirectory(at: placedDir, includingPropertiesForKeys: nil)
        return contents.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: - Konvertierungs-Dispatcher

    private static func convert(_ src: URL, _ dst: URL) throws {
        let data: Data
        do { data = try Data(contentsOf: src) } catch { throw ConvertError.unreadable }
        guard data.count >= 4 else { throw ConvertError.unreadable }

        let magic = try readUInt32BE(data, at: 0)
        let targetExt = dst.pathExtension.lowercased()

        if magic == ttcMagic {
            guard targetExt == "ttf" || targetExt == "otf" else { throw ConvertError.unsupported }
            let fonts = try parseTTC(data)
            guard !fonts.isEmpty else { throw ConvertError.unreadable }
            if fonts.count == 1 {
                try buildSFNT(fonts[0]).write(to: dst)
            } else {
                try FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true)
                for (index, font) in fonts.enumerated() {
                    let ext = font.flavor == sfntOTTO ? "otf" : "ttf"
                    let name = String(format: "Schrift-%03d.%@", index + 1, ext)
                    try buildSFNT(font).write(to: dst.appendingPathComponent(name))
                }
            }
            return
        }

        let sfnt: SFNTFont
        switch magic {
        case woff1Magic:
            sfnt = try decodeWOFF1(data)
        case woff2Magic:
            guard supportsBrotli else { throw ConvertError.unsupported }
            sfnt = try decodeWOFF2(data)
        case sfntTrueType, sfntOTTO, sfntAppleTrue, sfntTyp1:
            sfnt = try parseSFNT(data, tableDirectoryOffset: 0)
        default:
            throw ConvertError.unreadable
        }

        let output: Data
        switch targetExt {
        case "woff":
            output = try encodeWOFF1(sfnt)
        case "woff2":
            guard supportsBrotli else { throw ConvertError.unsupported }
            output = try encodeWOFF2(sfnt)
        case "ttf", "otf":
            output = try buildSFNT(sfnt)
        default:
            throw ConvertError.unsupported
        }

        do { try output.write(to: dst) } catch { throw ConvertError.writeFailed }
    }

    // MARK: - Konstanten & Datenmodell

    private static let sfntTrueType: UInt32 = 0x0001_0000
    private static let sfntOTTO: UInt32 = 0x4F54_544F      // 'OTTO'
    private static let sfntAppleTrue: UInt32 = 0x7472_7565 // 'true'
    private static let sfntTyp1: UInt32 = 0x7479_7031      // 'typ1'
    private static let ttcMagic: UInt32 = 0x7474_6366      // 'ttcf'
    private static let woff1Magic: UInt32 = 0x774F_4646    // 'wOFF'
    private static let woff2Magic: UInt32 = 0x774F_4632    // 'wOF2'

    private static let headTag: UInt32 = 0x6865_6164       // 'head'
    private static let glyfTag: UInt32 = 0x676C_7966       // 'glyf'
    private static let locaTag: UInt32 = 0x6C6F_6361       // 'loca'

    private struct SFNTTable: Sendable {
        let tag: UInt32
        let checkSum: UInt32
        let data: Data
    }

    private struct SFNTFont: Sendable {
        let flavor: UInt32
        let tables: [SFNTTable]
    }

    // MARK: - SFNT Lesen & Schreiben

    private static func parseTTC(_ data: Data) throws -> [SFNTFont] {
        guard data.count >= 12 else { throw ConvertError.unreadable }
        let tag = try readUInt32BE(data, at: 0)
        guard tag == ttcMagic else { throw ConvertError.unreadable }
        let major = try readUInt16BE(data, at: 4)
        guard major == 1 || major == 2 else { throw ConvertError.unreadable }
        let numFonts = Int(try readUInt32BE(data, at: 8))
        guard numFonts > 0, numFonts <= 1024 else { throw ConvertError.unreadable }
        let offsetsEnd = 12 + numFonts * 4
        guard offsetsEnd <= data.count else { throw ConvertError.unreadable }

        var fonts: [SFNTFont] = []
        fonts.reserveCapacity(numFonts)
        for i in 0..<numFonts {
            let dirOffset = Int(try readUInt32BE(data, at: 12 + i * 4))
            fonts.append(try parseSFNT(data, tableDirectoryOffset: dirOffset))
        }
        return fonts
    }

    private static func parseSFNT(_ data: Data, tableDirectoryOffset: Int) throws -> SFNTFont {
        guard tableDirectoryOffset >= 0, tableDirectoryOffset + 12 <= data.count else {
            throw ConvertError.unreadable
        }
        let flavor = try readUInt32BE(data, at: tableDirectoryOffset)
        guard flavor == sfntTrueType || flavor == sfntOTTO || flavor == sfntAppleTrue || flavor == sfntTyp1 else {
            throw ConvertError.unreadable
        }
        let numTables = Int(try readUInt16BE(data, at: tableDirectoryOffset + 4))
        guard numTables > 0 else { throw ConvertError.unreadable }

        let dirStart = tableDirectoryOffset + 12
        let dirEnd = dirStart + numTables * 16
        guard dirEnd <= data.count else { throw ConvertError.unreadable }

        var tables: [SFNTTable] = []
        tables.reserveCapacity(numTables)
        for i in 0..<numTables {
            let rec = dirStart + i * 16
            let tag = try readUInt32BE(data, at: rec)
            let checkSum = try readUInt32BE(data, at: rec + 4)
            let offset = Int(try readUInt32BE(data, at: rec + 8))
            let length = Int(try readUInt32BE(data, at: rec + 12))
            guard offset >= 0, length >= 0, offset + length <= data.count else {
                throw ConvertError.unreadable
            }
            let start = data.startIndex + offset
            let tableData = Data(data[start..<(start + length)])
            tables.append(SFNTTable(tag: tag, checkSum: checkSum, data: tableData))
        }
        return SFNTFont(flavor: flavor, tables: tables)
    }

    private static func buildSFNT(_ font: SFNTFont) throws -> Data {
        let sorted = font.tables.sorted { $0.tag < $1.tag }
        let numTables = sorted.count
        guard numTables > 0, numTables <= Int(UInt16.max) else { throw ConvertError.unreadable }

        let (searchRange, entrySelector, rangeShift) = sfntSearchParams(numTables: numTables)
        let headerSize = 12 + numTables * 16
        let totalSize = headerSize + sorted.reduce(0) { $0 + padded4($1.data.count) }

        var out = Data()
        out.reserveCapacity(totalSize)
        appendUInt32BE(font.flavor, to: &out)
        appendUInt16BE(UInt16(numTables), to: &out)
        appendUInt16BE(searchRange, to: &out)
        appendUInt16BE(entrySelector, to: &out)
        appendUInt16BE(rangeShift, to: &out)

        // Tabellen-Verzeichnis und vorbereitete Nutzdaten (bei `head` wird checkSumAdjustment vorerst genullt).
        var tablePayloads: [Data] = []
        tablePayloads.reserveCapacity(numTables)
        var headFileOffset: Int?
        var currentOffset = headerSize

        for table in sorted {
            var payload = table.data
            if table.tag == headTag, payload.count >= 12 {
                headFileOffset = currentOffset
                let s = payload.startIndex
                payload[s + 8] = 0
                payload[s + 9] = 0
                payload[s + 10] = 0
                payload[s + 11] = 0
            }
            let checkSum = sfntTableChecksum(payload)
            appendUInt32BE(table.tag, to: &out)
            appendUInt32BE(checkSum, to: &out)
            appendUInt32BE(UInt32(currentOffset), to: &out)
            appendUInt32BE(UInt32(payload.count), to: &out)

            tablePayloads.append(payload)
            currentOffset += padded4(payload.count)
        }

        for payload in tablePayloads {
            out.append(payload)
            appendZeroPadding(to: &out, alignment: 4)
        }

        if let headOffset = headFileOffset, headOffset + 12 <= out.count {
            let wholeChecksum = sfntTableChecksum(out)
            let adjustment: UInt32 = 0xB1B0_AFBA &- wholeChecksum
            writeUInt32BE(adjustment, into: &out, at: headOffset + 8)
        }

        return out
    }

    private static func sfntSearchParams(numTables: Int) -> (searchRange: UInt16, entrySelector: UInt16, rangeShift: UInt16) {
        var maxPow2 = 1
        var selector = 0
        while maxPow2 * 2 <= numTables {
            maxPow2 *= 2
            selector += 1
        }
        let searchRange = UInt16(maxPow2 * 16)
        let entrySelector = UInt16(selector)
        let rangeShift = UInt16(numTables * 16 - maxPow2 * 16)
        return (searchRange, entrySelector, rangeShift)
    }

    private static func sfntTableChecksum(_ data: Data) -> UInt32 {
        var sum: UInt32 = 0
        let count = data.count
        let start = data.startIndex
        var i = 0
        while i + 4 <= count {
            let b0 = UInt32(data[start + i])
            let b1 = UInt32(data[start + i + 1])
            let b2 = UInt32(data[start + i + 2])
            let b3 = UInt32(data[start + i + 3])
            sum &+= (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
            i += 4
        }
        if i < count {
            var tail: UInt32 = 0
            for j in 0..<(count - i) {
                tail |= UInt32(data[start + i + j]) << (24 - j * 8)
            }
            sum &+= tail
        }
        return sum
    }

    private static func totalSfntSize(for tables: [SFNTTable]) -> UInt32 {
        let header = 12 + tables.count * 16
        let body = tables.reduce(0) { $0 + padded4($1.data.count) }
        return UInt32(header + body)
    }

    // MARK: - WOFF 1.0 (wOFF)

    private static func encodeWOFF1(_ font: SFNTFont) throws -> Data {
        let sorted = font.tables.sorted { $0.tag < $1.tag }
        let numTables = sorted.count
        guard numTables > 0, numTables <= Int(UInt16.max) else { throw ConvertError.unreadable }

        struct Entry {
            let tag: UInt32
            let stored: Data
            let origLength: UInt32
            let origChecksum: UInt32
        }

        var entries: [Entry] = []
        entries.reserveCapacity(numTables)
        for table in sorted {
            let compressed = zlibCompress(table.data)
            let stored: Data
            if let compressed, compressed.count < table.data.count {
                stored = compressed
            } else {
                stored = table.data
            }
            entries.append(Entry(
                tag: table.tag,
                stored: stored,
                origLength: UInt32(table.data.count),
                origChecksum: table.checkSum
            ))
        }

        let headerAndDirSize = 44 + numTables * 20
        let totalWoffLength = headerAndDirSize + entries.reduce(0) { $0 + padded4($1.stored.count) }
        let sfntSize = totalSfntSize(for: sorted)

        var out = Data()
        out.reserveCapacity(totalWoffLength)
        appendUInt32BE(woff1Magic, to: &out)
        appendUInt32BE(font.flavor, to: &out)
        appendUInt32BE(UInt32(totalWoffLength), to: &out)
        appendUInt16BE(UInt16(numTables), to: &out)
        appendUInt16BE(0, to: &out) // reserved
        appendUInt32BE(sfntSize, to: &out)
        appendUInt16BE(1, to: &out) // majorVersion
        appendUInt16BE(0, to: &out) // minorVersion
        appendUInt32BE(0, to: &out) // metaOffset
        appendUInt32BE(0, to: &out) // metaLength
        appendUInt32BE(0, to: &out) // metaOrigLength
        appendUInt32BE(0, to: &out) // privOffset
        appendUInt32BE(0, to: &out) // privLength

        var offset = headerAndDirSize
        for entry in entries {
            appendUInt32BE(entry.tag, to: &out)
            appendUInt32BE(UInt32(offset), to: &out)
            appendUInt32BE(UInt32(entry.stored.count), to: &out)
            appendUInt32BE(entry.origLength, to: &out)
            appendUInt32BE(entry.origChecksum, to: &out)
            offset += padded4(entry.stored.count)
        }

        for entry in entries {
            out.append(entry.stored)
            appendZeroPadding(to: &out, alignment: 4)
        }

        return out
    }

    private static func decodeWOFF1(_ data: Data) throws -> SFNTFont {
        guard data.count >= 44 else { throw ConvertError.unreadable }
        guard try readUInt32BE(data, at: 0) == woff1Magic else { throw ConvertError.unreadable }
        let flavor = try readUInt32BE(data, at: 4)
        let numTables = Int(try readUInt16BE(data, at: 12))
        let reserved = try readUInt16BE(data, at: 14)
        guard numTables > 0, reserved == 0 else { throw ConvertError.unreadable }

        let dirEnd = 44 + numTables * 20
        guard dirEnd <= data.count else { throw ConvertError.unreadable }

        var tables: [SFNTTable] = []
        tables.reserveCapacity(numTables)
        for i in 0..<numTables {
            let rec = 44 + i * 20
            let tag = try readUInt32BE(data, at: rec)
            let offset = Int(try readUInt32BE(data, at: rec + 4))
            let compLength = Int(try readUInt32BE(data, at: rec + 8))
            let origLength = Int(try readUInt32BE(data, at: rec + 12))
            let origChecksum = try readUInt32BE(data, at: rec + 16)

            guard offset >= 0, compLength >= 0, origLength >= 0,
                  compLength <= origLength, offset + compLength <= data.count else {
                throw ConvertError.unreadable
            }

            let start = data.startIndex + offset
            let slice = Data(data[start..<(start + compLength)])
            let tableData: Data
            if compLength == origLength {
                tableData = slice
            } else {
                guard let decompressed = zlibDecompress(slice, expectedSize: origLength) else {
                    throw ConvertError.unreadable
                }
                tableData = decompressed
            }
            tables.append(SFNTTable(tag: tag, checkSum: origChecksum, data: tableData))
        }

        return SFNTFont(flavor: flavor, tables: tables)
    }

    // MARK: - WOFF 2.0 (wOF2)

    /// Bekannte Tabellen-Tags gemäß W3C WOFF 2.0 Abschnitt 5.1 (Indizes 0…59; 63 = freies 4-Byte-Tag).
    private static let woff2KnownTags: [UInt32] = [
        "cmap", "head", "hhea", "hmtx", "maxp", "name", "OS/2", "post",
        "cvt ", "fpgm", "glyf", "loca", "prep", "CFF ", "VORG", "EBDT",
        "EBLC", "gasp", "hdmx", "kern", "LTSH", "PCLT", "VDMX", "vhea",
        "vmtx", "BASE", "GDEF", "GPOS", "GSUB", "EBSC", "JSTF", "MATH",
        "CBDT", "CBLC", "COLR", "CPAL", "SVG ", "sbix", "acnt", "avar",
        "bdat", "bloc", "bsln", "cvar", "fvar", "gvar", "hsty", "just",
        "lcar", "mort", "morx", "opbd", "prop", "trak", "Zapf", "Silf",
        "Glat", "Gloc", "Feat", "Sill",
    ].map(fourCC)

    private static let woff2KnownTagIndex: [UInt32: UInt8] = {
        var map: [UInt32: UInt8] = [:]
        map.reserveCapacity(woff2KnownTags.count)
        for (i, tag) in woff2KnownTags.enumerated() { map[tag] = UInt8(i) }
        return map
    }()

    private static func encodeWOFF2(_ font: SFNTFont) throws -> Data {
        let sorted = font.tables.sorted { $0.tag < $1.tag }
        let numTables = sorted.count
        guard numTables > 0, numTables <= Int(UInt16.max) else { throw ConvertError.unreadable }

        // Tabellenverzeichnis aufbauen (alle Tabellen unverändert: transformVersion 3 für glyf/loca, 0 für alle anderen).
        var directory = Data()
        var rawStream = Data()
        rawStream.reserveCapacity(sorted.reduce(0) { $0 + $1.data.count })

        for table in sorted {
            let knownIndex = woff2KnownTagIndex[table.tag] ?? 63
            let transformVersion: UInt8 = (table.tag == glyfTag || table.tag == locaTag) ? 3 : 0
            let flags = (transformVersion << 6) | knownIndex
            directory.append(flags)
            if knownIndex == 63 {
                appendUInt32BE(table.tag, to: &directory)
            }
            appendUIntBase128(UInt32(table.data.count), to: &directory)
            rawStream.append(table.data)
        }

        guard let compressed = brotliCompress(rawStream) else { throw ConvertError.writeFailed }

        let sfntSize = totalSfntSize(for: sorted)
        let unpaddedLength = 48 + directory.count + compressed.count
        let totalLength = padded4(unpaddedLength)

        var out = Data()
        out.reserveCapacity(totalLength)
        appendUInt32BE(woff2Magic, to: &out)
        appendUInt32BE(font.flavor, to: &out)
        appendUInt32BE(UInt32(totalLength), to: &out)
        appendUInt16BE(UInt16(numTables), to: &out)
        appendUInt16BE(0, to: &out) // reserved
        appendUInt32BE(sfntSize, to: &out)
        appendUInt32BE(UInt32(compressed.count), to: &out)
        appendUInt16BE(1, to: &out) // majorVersion
        appendUInt16BE(0, to: &out) // minorVersion
        appendUInt32BE(0, to: &out) // metaOffset
        appendUInt32BE(0, to: &out) // metaLength
        appendUInt32BE(0, to: &out) // metaOrigLength
        appendUInt32BE(0, to: &out) // privOffset
        appendUInt32BE(0, to: &out) // privLength
        out.append(directory)
        out.append(compressed)
        appendZeroPadding(to: &out, alignment: 4)
        return out
    }

    private static func decodeWOFF2(_ data: Data) throws -> SFNTFont {
        guard data.count >= 48 else { throw ConvertError.unreadable }
        guard try readUInt32BE(data, at: 0) == woff2Magic else { throw ConvertError.unreadable }
        let flavor = try readUInt32BE(data, at: 4)
        guard flavor != ttcMagic else { throw ConvertError.unsupported }
        let numTables = Int(try readUInt16BE(data, at: 12))
        let reserved = try readUInt16BE(data, at: 14)
        let totalCompressedSize = Int(try readUInt32BE(data, at: 20))
        guard numTables > 0, reserved == 0, totalCompressedSize >= 0 else {
            throw ConvertError.unreadable
        }

        struct DirEntry {
            let tag: UInt32
            let origLength: Int
        }

        var cursor = 48
        var entries: [DirEntry] = []
        entries.reserveCapacity(numTables)
        var totalUncompressed = 0

        for _ in 0..<numTables {
            guard cursor < data.count else { throw ConvertError.unreadable }
            let flags = data[data.startIndex + cursor]
            cursor += 1

            let tagIndex = Int(flags & 0x3F)
            let transformVersion = (flags >> 6) & 0x03

            let tag: UInt32
            if tagIndex < woff2KnownTags.count {
                tag = woff2KnownTags[tagIndex]
            } else if tagIndex == 63 {
                tag = try readUInt32BE(data, at: cursor)
                cursor += 4
            } else {
                throw ConvertError.unsupported
            }

            let origLength = Int(try readUIntBase128(data, at: &cursor))
            let isTransformed = (tag == glyfTag || tag == locaTag) ? (transformVersion != 3) : (transformVersion != 0)
            if isTransformed {
                // Transformierte glyf/loca/hmtx-Tabellen erfordern den vollen WOFF2-Bytecode-Dekoder.
                throw ConvertError.unsupported
            }

            let (nextTotal, overflow) = totalUncompressed.addingReportingOverflow(origLength)
            guard !overflow else { throw ConvertError.unreadable }
            totalUncompressed = nextTotal
            entries.append(DirEntry(tag: tag, origLength: origLength))
        }

        guard cursor + totalCompressedSize <= data.count else { throw ConvertError.unreadable }
        let start = data.startIndex + cursor
        let compressedSlice = Data(data[start..<(start + totalCompressedSize)])

        guard let uncompressed = brotliDecompress(compressedSlice, expectedSize: totalUncompressed) else {
            throw ConvertError.unreadable
        }

        var tables: [SFNTTable] = []
        tables.reserveCapacity(numTables)
        var offset = 0
        for entry in entries {
            guard offset + entry.origLength <= uncompressed.count else { throw ConvertError.unreadable }
            let tStart = uncompressed.startIndex + offset
            let tableData = Data(uncompressed[tStart..<(tStart + entry.origLength)])
            tables.append(SFNTTable(tag: entry.tag, checkSum: sfntTableChecksum(tableData), data: tableData))
            offset += entry.origLength
        }

        return SFNTFont(flavor: flavor, tables: tables)
    }

    // MARK: - RFC 1950 zlib (Apple COMPRESSION_ZLIB liefert rohes RFC 1951 Deflate)

    private static func zlibCompress(_ input: Data) -> Data? {
        guard let rawDeflate = compressBuffer(input, algorithm: COMPRESSION_ZLIB) else { return nil }
        var out = Data()
        out.reserveCapacity(2 + rawDeflate.count + 4)
        out.append(0x78) // CMF: Deflate, 32K-Fenster
        out.append(0x9C) // FLG: Standard-Kompression, (0x789C % 31 == 0)
        out.append(rawDeflate)
        appendUInt32BE(adler32(input), to: &out)
        return out
    }

    private static func zlibDecompress(_ input: Data, expectedSize: Int) -> Data? {
        guard input.count >= 6 else { return nil }
        let s = input.startIndex
        let cmf = input[s]
        let flg = input[s + 1]
        guard (cmf & 0x0F) == 8, (cmf >> 4) <= 7 else { return nil }
        guard ((UInt16(cmf) << 8) | UInt16(flg)) % 31 == 0 else { return nil }
        guard (flg & 0x20) == 0 else { return nil } // kein Preset-Wörterbuch

        let rawDeflate = Data(input[(s + 2)..<(s + input.count - 4)])
        guard let expectedAdler = try? readUInt32BE(input, at: input.count - 4),
              let decompressed = decompressBuffer(rawDeflate, expectedSize: expectedSize, algorithm: COMPRESSION_ZLIB),
              adler32(decompressed) == expectedAdler
        else { return nil }
        return decompressed
    }

    private static func adler32(_ data: Data) -> UInt32 {
        let mod: UInt32 = 65521
        var s1: UInt32 = 1
        var s2: UInt32 = 0
        data.withUnsafeBytes { raw in
            guard let ptr = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            var remaining = raw.count
            var idx = 0
            while remaining > 0 {
                let chunk = min(remaining, 2048)
                for _ in 0..<chunk {
                    s1 &+= UInt32(ptr[idx])
                    s2 &+= s1
                    idx += 1
                }
                s1 %= mod
                s2 %= mod
                remaining -= chunk
            }
        }
        return (s2 << 16) | s1
    }

    // MARK: - Brotli & Compression-Puffer

    private static func brotliCompress(_ input: Data) -> Data? {
        compressBuffer(input, algorithm: COMPRESSION_BROTLI)
    }

    private static func brotliDecompress(_ input: Data, expectedSize: Int) -> Data? {
        decompressBuffer(input, expectedSize: expectedSize, algorithm: COMPRESSION_BROTLI)
    }

    private static func compressBuffer(_ input: Data, algorithm: compression_algorithm) -> Data? {
        if input.isEmpty {
            let emptyCap = 64
            var dst = [UInt8](repeating: 0, count: emptyCap)
            var empty: UInt8 = 0
            let written = compression_encode_buffer(&dst, emptyCap, &empty, 0, nil, algorithm)
            return written > 0 ? Data(dst.prefix(written)) : nil
        }

        var capacity = max(input.count + 1024, input.count + input.count / 4 + 64)
        for _ in 0..<2 {
            var dst = [UInt8](repeating: 0, count: capacity)
            let written: Int = input.withUnsafeBytes { raw in
                guard let srcPtr = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_encode_buffer(&dst, capacity, srcPtr, raw.count, nil, algorithm)
            }
            if written > 0 {
                return Data(dst.prefix(written))
            }
            capacity *= 2
        }
        return nil
    }

    private static func decompressBuffer(_ input: Data, expectedSize: Int, algorithm: compression_algorithm) -> Data? {
        if expectedSize == 0 { return Data() }
        guard !input.isEmpty else { return nil }
        // +64 Reserve, damit ein zu großer Stream nicht still abgeschnitten wird.
        let capacity = expectedSize + 64
        var dst = [UInt8](repeating: 0, count: capacity)
        let written: Int = input.withUnsafeBytes { raw in
            guard let srcPtr = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_decode_buffer(&dst, capacity, srcPtr, raw.count, nil, algorithm)
        }
        guard written == expectedSize else { return nil }
        return Data(dst.prefix(written))
    }

    // MARK: - Binär-Hilfsfunktionen

    private static func fourCC(_ s: String) -> UInt32 {
        let bytes = Array(s.utf8)
        precondition(bytes.count == 4)
        return (UInt32(bytes[0]) << 24) | (UInt32(bytes[1]) << 16) | (UInt32(bytes[2]) << 8) | UInt32(bytes[3])
    }

    private static func padded4(_ n: Int) -> Int {
        (n + 3) & ~3
    }

    private static func appendZeroPadding(to data: inout Data, alignment: Int) {
        let rem = data.count % alignment
        if rem != 0 {
            data.append(contentsOf: repeatElement(UInt8(0), count: alignment - rem))
        }
    }

    private static func readUInt16BE(_ data: Data, at offset: Int) throws -> UInt16 {
        guard offset >= 0, offset + 2 <= data.count else { throw ConvertError.unreadable }
        let i = data.startIndex + offset
        return (UInt16(data[i]) << 8) | UInt16(data[i + 1])
    }

    private static func readUInt32BE(_ data: Data, at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { throw ConvertError.unreadable }
        let i = data.startIndex + offset
        return (UInt32(data[i]) << 24) | (UInt32(data[i + 1]) << 16)
             | (UInt32(data[i + 2]) << 8) | UInt32(data[i + 3])
    }

    private static func appendUInt16BE(_ value: UInt16, to data: inout Data) {
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }

    private static func appendUInt32BE(_ value: UInt32, to data: inout Data) {
        data.append(UInt8((value >> 24) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }

    private static func writeUInt32BE(_ value: UInt32, into data: inout Data, at offset: Int) {
        let i = data.startIndex + offset
        data[i] = UInt8((value >> 24) & 0xFF)
        data[i + 1] = UInt8((value >> 16) & 0xFF)
        data[i + 2] = UInt8((value >> 8) & 0xFF)
        data[i + 3] = UInt8(value & 0xFF)
    }

    private static func appendUIntBase128(_ value: UInt32, to data: inout Data) {
        if value == 0 {
            data.append(0)
            return
        }
        var groups: [UInt8] = []
        var v = value
        while v > 0 {
            groups.append(UInt8(v & 0x7F))
            v >>= 7
        }
        for i in stride(from: groups.count - 1, through: 0, by: -1) {
            data.append(groups[i] | (i > 0 ? 0x80 : 0))
        }
    }

    private static func readUIntBase128(_ data: Data, at offset: inout Int) throws -> UInt32 {
        var accum: UInt32 = 0
        for i in 0..<5 {
            guard offset < data.count else { throw ConvertError.unreadable }
            let byte = data[data.startIndex + offset]
            offset += 1
            if i == 0 && byte == 0x80 { throw ConvertError.unreadable }
            if (accum & 0xFE00_0000) != 0 { throw ConvertError.unreadable }
            accum = (accum << 7) | UInt32(byte & 0x7F)
            if (byte & 0x80) == 0 { return accum }
        }
        throw ConvertError.unreadable
    }
}
