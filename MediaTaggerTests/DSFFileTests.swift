import XCTest
@testable import MediaTagger

final class DSFFileTests: XCTestCase {

    private var fileURL: URL!
    /// Pretend DSD audio body — content we want preserved verbatim.
    private let dsdAudio = Data((0..<128).map { UInt8($0 & 0xFF) })

    override func setUpWithError() throws {
        fileURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MediaTaggerDSFTest-\(UUID().uuidString).dsf")
        try makeMinimalDSF().write(to: fileURL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Build a minimal valid DSF: DSD header + fmt chunk + data chunk, no ID3.
    private func makeMinimalDSF() -> Data {
        // fmt chunk (52 bytes total, including 12-byte header).
        var fmtBody = Data()
        fmtBody.append(leU32(1))       // format version
        fmtBody.append(leU32(0))       // format ID (0 = DSD raw)
        fmtBody.append(leU32(2))       // channel type
        fmtBody.append(leU32(2))       // channel num
        fmtBody.append(leU32(2822400)) // sample rate
        fmtBody.append(leU32(1))       // bits per sample
        fmtBody.append(leU64(UInt64(dsdAudio.count) * 8 / 2)) // sample count
        fmtBody.append(leU32(4096))    // block size per channel
        fmtBody.append(leU32(0))       // reserved
        precondition(fmtBody.count == 40, "fmt body size wrong")

        var fmt = Data()
        fmt.append(Data("fmt ".utf8))
        fmt.append(leU64(52))          // chunk size = 12 + 40
        fmt.append(fmtBody)

        // data chunk: header (12 bytes) + audio.
        var dataChunk = Data()
        dataChunk.append(Data("data".utf8))
        dataChunk.append(leU64(UInt64(12 + dsdAudio.count)))
        dataChunk.append(dsdAudio)

        // DSD chunk (28 bytes).
        let totalSize = UInt64(28 + fmt.count + dataChunk.count)
        var dsd = Data()
        dsd.append(Data("DSD ".utf8))
        dsd.append(leU64(28))          // chunk size
        dsd.append(leU64(totalSize))   // total file size
        dsd.append(leU64(0))           // metadata pointer (none yet)

        var out = Data()
        out.append(dsd)
        out.append(fmt)
        out.append(dataChunk)
        return out
    }

    private func leU32(_ v: UInt32) -> Data {
        Data([UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF),
              UInt8(v >> 16 & 0xFF), UInt8(v >> 24 & 0xFF)])
    }
    private func leU64(_ v: UInt64) -> Data {
        var out = [UInt8](repeating: 0, count: 8)
        for i in 0..<8 { out[i] = UInt8((v >> (8 * i)) & 0xFF) }
        return Data(out)
    }
    private func readLEU64(_ d: Data, _ p: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(d[p+i]) << (8*i) }
        return v
    }

    // MARK: - tests

    func testWriteCreatesID3AndPreservesAudio() throws {
        try DSFFile.write(url: fileURL, entries: [
            ("TITLE", "Hello DSF"),
            ("ARTIST", "Tester"),
            ("ALBUM", "Album X"),
            ("ALBUMARTIST", "Various"),
            ("DATE", "2026"),
            ("GENRE", "Classical"),
            ("COMPOSER", "Alice"),
            ("COMMENT", "Unicode: 你好"),
            ("TRACKNUMBER", "3"),
            ("TRACKTOTAL", "12"),
            ("DISCNUMBER", "1"),
            ("DISCTOTAL", "2"),
        ], cover: nil)

        let parsed = try DSFFile.read(fileURL)
        let (entries, _) = parsed.decoded()
        let dict = Dictionary(entries.map { ($0.key, $0.value) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(dict["TITLE"], "Hello DSF")
        XCTAssertEqual(dict["ARTIST"], "Tester")
        XCTAssertEqual(dict["ALBUM"], "Album X")
        XCTAssertEqual(dict["ALBUMARTIST"], "Various")
        XCTAssertEqual(dict["DATE"], "2026")
        XCTAssertEqual(dict["GENRE"], "Classical")
        XCTAssertEqual(dict["COMPOSER"], "Alice")
        XCTAssertEqual(dict["COMMENT"], "Unicode: 你好")
        XCTAssertEqual(dict["TRACKNUMBER"], "3")
        XCTAssertEqual(dict["TRACKTOTAL"], "12")
        XCTAssertEqual(dict["DISCNUMBER"], "1")
        XCTAssertEqual(dict["DISCTOTAL"], "2")

        // DSD audio preserved.
        let raw = try Data(contentsOf: fileURL)
        XCTAssertNotNil(raw.range(of: dsdAudio), "DSD audio body must remain intact")
    }

    func testCoverArtRoundTrip() throws {
        let png = Data([
            0x89,0x50,0x4E,0x47,0x0D,0x0A,0x1A,0x0A,
            0x00,0x00,0x00,0x0D,0x49,0x48,0x44,0x52,
            0x00,0x00,0x00,0x01,0x00,0x00,0x00,0x01,
            0x08,0x06,0x00,0x00,0x00,0x1F,0x15,0xC4,0x89,
            0x00,0x00,0x00,0x0D,0x49,0x44,0x41,0x54,
            0x78,0x9C,0x62,0x00,0x01,0x00,0x00,0x05,0x00,0x01,0x0D,0x0A,0x2D,0xB4,
            0x00,0x00,0x00,0x00,0x49,0x45,0x4E,0x44,0xAE,0x42,0x60,0x82
        ])
        try DSFFile.write(url: fileURL,
                         entries: [("TITLE", "with art")],
                         cover: (png, "image/png"))
        let (_, cover) = try DSFFile.read(fileURL).decoded()
        XCTAssertEqual(cover?.mime, "image/png")
        XCTAssertEqual(cover?.data, png)
    }

    func testRewriteReplacesPreviousTagAndUpdatesHeader() throws {
        try DSFFile.write(url: fileURL, entries: [("TITLE", "first")], cover: nil)
        try DSFFile.write(url: fileURL, entries: [("TITLE", "second")], cover: nil)

        // Verify only one tag round-trips back.
        let (entries, _) = try DSFFile.read(fileURL).decoded()
        let titles = entries.filter { $0.key == "TITLE" }
        XCTAssertEqual(titles.count, 1)
        XCTAssertEqual(titles.first?.value, "second")

        // Header fields must match the actual file.
        let raw = try Data(contentsOf: fileURL)
        XCTAssertEqual(readLEU64(raw, 12), UInt64(raw.count))
        let metaPtr = readLEU64(raw, 20)
        XCTAssertGreaterThan(metaPtr, 0)
        XCTAssertLessThan(metaPtr, UInt64(raw.count))
        // Tag at metaPtr starts with "ID3".
        XCTAssertEqual(raw[Int(metaPtr)],     0x49)
        XCTAssertEqual(raw[Int(metaPtr) + 1], 0x44)
        XCTAssertEqual(raw[Int(metaPtr) + 2], 0x33)

        // DSD audio still present.
        XCTAssertNotNil(raw.range(of: dsdAudio))
    }

    func testMetadataServiceDSFRoundTrip() throws {
        let svc = MetadataService()
        var md = try svc.read(fileURL)
        md.setTag("TITLE", "From Service")
        md.setTag("ARTIST", "Pal")
        md.setTag("TRACKNUMBER", "5")
        md.setTag("TRACKTOTAL", "10")
        try svc.write(md, to: fileURL)

        let again = try svc.read(fileURL)
        XCTAssertEqual(again.title, "From Service")
        XCTAssertEqual(again.first("ARTIST"), "Pal")
        XCTAssertEqual(again.first("TRACKNUMBER"), "5")
        XCTAssertEqual(again.first("TRACKTOTAL"), "10")
    }
}
