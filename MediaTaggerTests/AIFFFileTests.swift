import XCTest
@testable import MediaTagger

final class AIFFFileTests: XCTestCase {

    private var fileURL: URL!
    /// Pretend SSND payload — 9 bytes (odd) to exercise the AIFF pad-byte logic.
    private let ssndPayload = Data("FAKEAUDIO".utf8)
    /// Pretend COMM (AIFF Common chunk) payload — even length.
    private let commPayload = Data([0,1, 0,0,0,2, 0,16, 0x40,0x0E,0xAC,0x44,0,0,0,0,0,0])

    override func setUpWithError() throws {
        fileURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MediaTaggerAIFFTest-\(UUID().uuidString).aiff")
        try makeMinimalAIFF().write(to: fileURL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Build a tiny AIFF: FORM { AIFF + COMM + SSND } with no ID3 chunk yet.
    private func makeMinimalAIFF() -> Data {
        var chunks = Data()
        chunks.append(chunk(id: "COMM", payload: commPayload))
        chunks.append(chunk(id: "SSND", payload: ssndPayload))   // odd -> 1 pad byte
        var out = Data()
        out.append(Data("FORM".utf8))
        out.append(beU32(UInt32(4 + chunks.count)))
        out.append(Data("AIFF".utf8))
        out.append(chunks)
        return out
    }

    private func chunk(id: String, payload: Data) -> Data {
        var d = Data()
        d.append(Data(id.utf8))
        d.append(beU32(UInt32(payload.count)))
        d.append(payload)
        if payload.count & 1 == 1 { d.append(0) }
        return d
    }

    private func beU32(_ v: UInt32) -> Data {
        Data([UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF),
              UInt8(v >> 8  & 0xFF), UInt8(v       & 0xFF)])
    }

    // MARK: - tests

    func testWriteCreatesID3AndPreservesAudio() throws {
        try AIFFFile.write(url: fileURL, entries: [
            ("TITLE", "Hello AIFF"),
            ("ARTIST", "Tester"),
            ("ALBUM", "Album X"),
            ("ALBUMARTIST", "Various"),
            ("DATE", "2026"),
            ("GENRE", "Electronic"),
            ("COMPOSER", "Alice"),
            ("COMMENT", "Unicode: 你好"),
            ("TRACKNUMBER", "3"),
            ("TRACKTOTAL", "12"),
            ("DISCNUMBER", "1"),
            ("DISCTOTAL", "2"),
        ], cover: nil)

        // Re-read.
        let parsed = try AIFFFile.read(fileURL)
        let (entries, _) = parsed.decoded()
        let dict = Dictionary(entries.map { ($0.key, $0.value) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(dict["TITLE"], "Hello AIFF")
        XCTAssertEqual(dict["ARTIST"], "Tester")
        XCTAssertEqual(dict["ALBUM"], "Album X")
        XCTAssertEqual(dict["ALBUMARTIST"], "Various")
        XCTAssertEqual(dict["DATE"], "2026")
        XCTAssertEqual(dict["GENRE"], "Electronic")
        XCTAssertEqual(dict["COMPOSER"], "Alice")
        XCTAssertEqual(dict["COMMENT"], "Unicode: 你好")
        XCTAssertEqual(dict["TRACKNUMBER"], "3")
        XCTAssertEqual(dict["TRACKTOTAL"], "12")
        XCTAssertEqual(dict["DISCNUMBER"], "1")
        XCTAssertEqual(dict["DISCTOTAL"], "2")

        // Audio chunk preserved.
        let raw = try Data(contentsOf: fileURL)
        XCTAssertNotNil(raw.range(of: ssndPayload), "SSND payload must remain intact")
        XCTAssertNotNil(raw.range(of: commPayload), "COMM payload must remain intact")
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
        try AIFFFile.write(url: fileURL,
                          entries: [("TITLE", "with art")],
                          cover: (png, "image/png"))

        let (_, cover) = try AIFFFile.read(fileURL).decoded()
        XCTAssertEqual(cover?.mime, "image/png")
        XCTAssertEqual(cover?.data, png)
    }

    func testRewriteReplacesPreviousTags() throws {
        try AIFFFile.write(url: fileURL, entries: [("TITLE", "first")], cover: nil)
        try AIFFFile.write(url: fileURL, entries: [("TITLE", "second")], cover: nil)

        let (entries, _) = try AIFFFile.read(fileURL).decoded()
        let titles = entries.filter { $0.key == "TITLE" }
        XCTAssertEqual(titles.count, 1)
        XCTAssertEqual(titles.first?.value, "second")

        // Verify there is exactly one ID3 chunk in the file.
        let raw = try Data(contentsOf: fileURL)
        var count = 0
        var p = 12
        while p + 8 <= raw.count {
            let id = String(data: raw.subdata(in: p..<p+4), encoding: .ascii) ?? ""
            let size = Int((UInt32(raw[p+4]) << 24) | (UInt32(raw[p+5]) << 16) |
                           (UInt32(raw[p+6]) << 8)  |  UInt32(raw[p+7]))
            if id == "ID3 " { count += 1 }
            p += 8 + size + (size & 1)
        }
        XCTAssertEqual(count, 1)
    }

    func testFormSizeIsCorrectAfterWrite() throws {
        try AIFFFile.write(url: fileURL,
                          entries: [("TITLE", "size-check")], cover: nil)
        let raw = try Data(contentsOf: fileURL)
        let formSize = (UInt32(raw[4]) << 24) | (UInt32(raw[5]) << 16) |
                       (UInt32(raw[6]) << 8)  |  UInt32(raw[7])
        // FORM size counts everything after the 8-byte header.
        XCTAssertEqual(Int(formSize), raw.count - 8)
    }

    func testMetadataServiceAIFFRoundTrip() throws {
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
