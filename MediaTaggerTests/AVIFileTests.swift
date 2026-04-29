import XCTest
@testable import MediaTagger

final class AVIFileTests: XCTestCase {

    private var fileURL: URL!
    /// Stand-in "video" body — odd length to exercise the pad-byte logic.
    private let moviPayload = Data("FAKEMOVI".utf8 + [0x42])

    override func setUpWithError() throws {
        fileURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MediaTaggerAVITest-\(UUID().uuidString).avi")
        try makeMinimalAVI().write(to: fileURL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// RIFF + "AVI " + one fake "movi" chunk. Enough for our parser/writer
    /// to round-trip.
    private func makeMinimalAVI() -> Data {
        var chunks = Data()
        chunks.append(chunk(id: "movi", payload: moviPayload))   // odd ⇒ 1 pad
        var out = Data()
        out.append(Data("RIFF".utf8))
        out.append(leU32(UInt32(4 + chunks.count)))
        out.append(Data("AVI ".utf8))
        out.append(chunks)
        return out
    }

    private func chunk(id: String, payload: Data) -> Data {
        var d = Data()
        d.append(Data(id.utf8))
        d.append(leU32(UInt32(payload.count)))
        d.append(payload)
        if payload.count & 1 == 1 { d.append(0) }
        return d
    }

    private func leU32(_ v: UInt32) -> Data {
        Data([UInt8(v        & 0xFF), UInt8(v >> 8  & 0xFF),
              UInt8(v >> 16 & 0xFF), UInt8(v >> 24 & 0xFF)])
    }

    // MARK: - tests

    func testWriteCreatesInfoListAndPreservesMovi() throws {
        try AVIFile.write(url: fileURL, entries: [
            ("TITLE",   "Hello AVI"),
            ("ARTIST",  "Tester"),
            ("ALBUM",   "Album X"),
            ("DATE",    "2026"),
            ("GENRE",   "Action"),
            ("COMMENT", "Unicode: 你好"),
            ("COMPOSER", "Alice"),
            ("TRACKNUMBER", "3"),
            ("TRACKTOTAL",  "12"),
        ])

        let parsed = try AVIFile.read(fileURL)
        let dict = Dictionary(parsed.entries.map { ($0.key, $0.value) },
                              uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(dict["TITLE"],    "Hello AVI")
        XCTAssertEqual(dict["ARTIST"],   "Tester")
        XCTAssertEqual(dict["ALBUM"],    "Album X")
        XCTAssertEqual(dict["DATE"],     "2026")
        XCTAssertEqual(dict["GENRE"],    "Action")
        XCTAssertEqual(dict["COMMENT"],  "Unicode: 你好")
        XCTAssertEqual(dict["COMPOSER"], "Alice")
        // Track number/total combined into "n/total".
        XCTAssertEqual(dict["TRACKNUMBER"], "3/12")

        // movi chunk preserved.
        let raw = try Data(contentsOf: fileURL)
        XCTAssertNotNil(raw.range(of: moviPayload))
    }

    func testRewriteReplacesPreviousInfoList() throws {
        try AVIFile.write(url: fileURL, entries: [("TITLE", "first")])
        try AVIFile.write(url: fileURL, entries: [("TITLE", "second")])

        let parsed = try AVIFile.read(fileURL)
        let titles = parsed.entries.filter { $0.key == "TITLE" }
        XCTAssertEqual(titles.count, 1)
        XCTAssertEqual(titles.first?.value, "second")

        // Verify exactly one LIST/INFO chunk in the file.
        let raw = try Data(contentsOf: fileURL)
        var listInfoCount = 0
        var p = 12
        while p + 8 <= raw.count {
            let id = String(data: raw.subdata(in: p..<p+4), encoding: .ascii) ?? ""
            let size = Int(UInt32(raw[p+4]) | (UInt32(raw[p+5]) << 8) |
                           (UInt32(raw[p+6]) << 16) | (UInt32(raw[p+7]) << 24))
            if id == "LIST", p + 12 <= raw.count,
               String(data: raw.subdata(in: p+8..<p+12), encoding: .ascii) == "INFO" {
                listInfoCount += 1
            }
            p += 8 + size + (size & 1)
        }
        XCTAssertEqual(listInfoCount, 1)
    }

    func testRiffSizeIsCorrectAfterWrite() throws {
        try AVIFile.write(url: fileURL, entries: [("TITLE", "size-check")])
        let raw = try Data(contentsOf: fileURL)
        let riffSize = UInt32(raw[4]) | (UInt32(raw[5]) << 8) |
                       (UInt32(raw[6]) << 16) | (UInt32(raw[7]) << 24)
        XCTAssertEqual(Int(riffSize), raw.count - 8)
    }

    func testMetadataServiceAVIRoundTrip() throws {
        let svc = MetadataService()
        var md = try svc.read(fileURL)
        md.setTag("TITLE", "From Service")
        md.setTag("ARTIST", "Pal")
        try svc.write(md, to: fileURL)

        let again = try svc.read(fileURL)
        XCTAssertEqual(again.title, "From Service")
        XCTAssertEqual(again.first("ARTIST"), "Pal")
    }
}
