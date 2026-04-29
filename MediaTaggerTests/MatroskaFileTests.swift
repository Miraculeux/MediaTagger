import XCTest
@testable import MediaTagger

final class MatroskaFileTests: XCTestCase {

    private var fileURL: URL!

    override func setUpWithError() throws {
        fileURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MediaTaggerMKVTest-\(UUID().uuidString).mka")
        try makeMinimalMKV().write(to: fileURL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Build a tiny EBML+Segment skeleton: just an EBML header and an empty
    /// (unknown-size) Segment. Enough for our parser to find the Segment body.
    private func makeMinimalMKV() -> Data {
        // EBML header with EBMLVersion=1.
        // Element IDs:
        //   EBML       = 0x1A45DFA3
        //   EBMLVersion= 0x4286 (UInt 1)
        var ebmlBody = Data()
        ebmlBody.append(contentsOf: [0x42, 0x86])      // EBMLVersion ID
        ebmlBody.append(contentsOf: [0x81, 0x01])      // size=1, value=1
        let ebmlHeader = element(id: [0x1A,0x45,0xDF,0xA3], payload: ebmlBody)

        // Segment with unknown length (VINT 0xFF), containing nothing yet.
        var seg = Data()
        seg.append(contentsOf: [0x18, 0x53, 0x80, 0x67])  // Segment ID
        seg.append(0xFF)                                   // unknown size

        var out = Data()
        out.append(ebmlHeader)
        out.append(seg)
        return out
    }

    private func element(id: [UInt8], payload: Data) -> Data {
        var d = Data()
        d.append(Data(id))
        d.append(encodeSize(UInt64(payload.count)))
        d.append(payload)
        return d
    }

    private func encodeSize(_ value: UInt64) -> Data {
        for n in 1...8 {
            let max: UInt64 = (UInt64(1) << UInt64(7 * n)) - 1
            if value < max {
                var bytes = [UInt8](repeating: 0, count: n)
                var v = value
                for i in stride(from: n - 1, through: 1, by: -1) {
                    bytes[i] = UInt8(v & 0xFF); v >>= 8
                }
                bytes[0] = UInt8(v) | UInt8(0x80 >> (n - 1))
                return Data(bytes)
            }
        }
        return Data([0xFF])
    }

    // MARK: - tests

    func testWriteAndReadBackTags() throws {
        try MatroskaFile.write(url: fileURL, entries: [
            ("TITLE", "Hello MKV"),
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

        let parsed = try MatroskaFile.read(fileURL)
        let dict = Dictionary(parsed.entries.map { ($0.key, $0.value) },
                              uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(dict["TITLE"], "Hello MKV")
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
        XCTAssertNil(parsed.cover)
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
        try MatroskaFile.write(url: fileURL,
                              entries: [("TITLE", "with art")],
                              cover: (png, "image/png"))

        let parsed = try MatroskaFile.read(fileURL)
        XCTAssertEqual(parsed.cover?.mime, "image/png")
        XCTAssertEqual(parsed.cover?.data, png)
        XCTAssertEqual(parsed.entries.first(where: { $0.key == "TITLE" })?.value, "with art")
    }

    func testRewriteReplacesPreviousTags() throws {
        try MatroskaFile.write(url: fileURL, entries: [("TITLE", "first")], cover: nil)
        try MatroskaFile.write(url: fileURL, entries: [("TITLE", "second")], cover: nil)

        let parsed = try MatroskaFile.read(fileURL)
        let titles = parsed.entries.filter { $0.key == "TITLE" }
        XCTAssertEqual(titles.count, 1)
        XCTAssertEqual(titles.first?.value, "second")
    }

    func testMetadataServiceMatroskaRoundTrip() throws {
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

    func testMetadataServiceWebMRoundTrip() throws {
        // Same EBML container; just a different extension. The MetadataService
        // dispatch must accept .webm and the writer must produce a parseable file.
        let webm = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MediaTaggerWebMTest-\(UUID().uuidString).webm")
        try makeMinimalMKV().write(to: webm)
        defer { try? FileManager.default.removeItem(at: webm) }

        let svc = MetadataService()
        var md = try svc.read(webm)
        md.setTag("TITLE", "WebM Title")
        md.setTag("ARTIST", "WebM Artist")
        try svc.write(md, to: webm)

        let again = try svc.read(webm)
        XCTAssertEqual(again.title, "WebM Title")
        XCTAssertEqual(again.first("ARTIST"), "WebM Artist")
    }
}
