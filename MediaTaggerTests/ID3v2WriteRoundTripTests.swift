import XCTest
@testable import MediaTagger

final class ID3v2WriteRoundTripTests: XCTestCase {

    private var fileURL: URL!
    private let audioMarker = Data("FAKEMP3DATA".utf8)

    override func setUpWithError() throws {
        fileURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MediaTaggerTest-\(UUID().uuidString).mp3")
        // No initial ID3v2 tag — just fake "audio" payload.
        try audioMarker.write(to: fileURL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: fileURL)
    }

    func testWriteCreatesTagAndPreservesAudio() throws {
        try ID3v2File.write(url: fileURL, entries: [
            ("TITLE", "Hello MP3"),
            ("ARTIST", "Tester"),
            ("ALBUM", "Album X"),
            ("TRACKNUMBER", "3"),
            ("TRACKTOTAL", "12"),
            ("DISCNUMBER", "1"),
            ("DISCTOTAL", "2"),
            ("DATE", "2026"),
            ("GENRE", "Electronic"),
            ("COMMENT", "A nice comment with unicode: 你好"),
        ], cover: nil)

        // Re-read and verify.
        let parsed = try ID3v2File.read(fileURL)
        XCTAssertFalse(parsed.frames.isEmpty)
        let (entries, _) = parsed.decoded()
        let dict = Dictionary(entries.map { ($0.key, $0.value) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(dict["TITLE"], "Hello MP3")
        XCTAssertEqual(dict["ARTIST"], "Tester")
        XCTAssertEqual(dict["ALBUM"], "Album X")
        XCTAssertEqual(dict["TRACKNUMBER"], "3")
        XCTAssertEqual(dict["TRACKTOTAL"], "12")
        XCTAssertEqual(dict["DISCNUMBER"], "1")
        XCTAssertEqual(dict["DISCTOTAL"], "2")
        XCTAssertEqual(dict["DATE"], "2026")
        XCTAssertEqual(dict["GENRE"], "Electronic")
        XCTAssertEqual(dict["COMMENT"], "A nice comment with unicode: 你好")

        // Audio body preserved.
        let raw = try Data(contentsOf: fileURL)
        XCTAssertNotNil(raw.range(of: audioMarker), "Audio body should remain intact")
    }

    func testCoverArtRoundTrip() throws {
        // 1x1 PNG.
        let png = Data([
            0x89,0x50,0x4E,0x47,0x0D,0x0A,0x1A,0x0A,
            0x00,0x00,0x00,0x0D,0x49,0x48,0x44,0x52,
            0x00,0x00,0x00,0x01,0x00,0x00,0x00,0x01,
            0x08,0x06,0x00,0x00,0x00,0x1F,0x15,0xC4,0x89,
            0x00,0x00,0x00,0x0D,0x49,0x44,0x41,0x54,
            0x78,0x9C,0x62,0x00,0x01,0x00,0x00,0x05,0x00,0x01,0x0D,0x0A,0x2D,0xB4,
            0x00,0x00,0x00,0x00,0x49,0x45,0x4E,0x44,0xAE,0x42,0x60,0x82
        ])
        try ID3v2File.write(url: fileURL,
                            entries: [("TITLE", "with art")],
                            cover: (png, "image/png"))

        let parsed = try ID3v2File.read(fileURL)
        let (_, cover) = parsed.decoded()
        XCTAssertEqual(cover?.mime, "image/png")
        XCTAssertEqual(cover?.data, png)
    }

    func testWriteThenRewriteReplacesFrames() throws {
        try ID3v2File.write(url: fileURL, entries: [("TITLE", "first")], cover: nil)
        try ID3v2File.write(url: fileURL, entries: [("TITLE", "second")], cover: nil)

        let parsed = try ID3v2File.read(fileURL)
        let titles = parsed.frames.filter { $0.id == "TIT2" }
        XCTAssertEqual(titles.count, 1)
        let (entries, _) = parsed.decoded()
        XCTAssertEqual(entries.first(where: { $0.key == "TITLE" })?.value, "second")

        // Audio still preserved.
        let raw = try Data(contentsOf: fileURL)
        XCTAssertNotNil(raw.range(of: audioMarker))
    }

    func testMetadataServiceRoundTrip() throws {
        let svc = MetadataService()
        var md = try svc.read(fileURL)        // empty initially
        md.setTag("TITLE", "From Service")
        md.setTag("TRACKNUMBER", "5")
        md.setTag("TRACKTOTAL", "10")
        try svc.write(md, to: fileURL)

        let again = try svc.read(fileURL)
        XCTAssertEqual(again.title, "From Service")
        XCTAssertEqual(again.first("TRACKNUMBER"), "5")
        XCTAssertEqual(again.first("TRACKTOTAL"), "10")
    }
}
