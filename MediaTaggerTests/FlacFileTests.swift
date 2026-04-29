import XCTest
@testable import MediaTagger

final class FlacFileTests: XCTestCase {

    func testVorbisCommentRoundTrip() throws {
        let vc = VorbisComment(
            vendor: "MediaTagger 0.1",
            entries: [
                ("TITLE", "Hello, 世界"),
                ("ARTIST", "Test Artist"),
                ("ALBUM", "An Album"),
                ("TRACKNUMBER", "1"),
            ]
        )
        let encoded = vc.encode()
        let decoded = try VorbisComment.decode(encoded)
        XCTAssertEqual(decoded.vendor, vc.vendor)
        XCTAssertEqual(decoded.entries.map { $0.key }, vc.entries.map { $0.key })
        XCTAssertEqual(decoded.entries.map { $0.value }, vc.entries.map { $0.value })
    }

    func testFlacParseRejectsNonFlac() {
        let junk = Data([0x00, 0x01, 0x02, 0x03])
        XCTAssertThrowsError(try FlacFile.parse(junk, url: URL(fileURLWithPath: "/tmp/x.flac")))
    }

    func testFlacParseMinimalSynthetic() throws {
        // Build a minimal synthetic FLAC: "fLaC" + STREAMINFO (34 zero bytes) marked last.
        var data = Data([0x66, 0x4C, 0x61, 0x43])
        data.append(0x80) // last=1, type=0 (STREAMINFO)
        data.append(contentsOf: [0x00, 0x00, 0x22]) // length 34
        data.append(Data(count: 34))
        let parsed = try FlacFile.parse(data, url: URL(fileURLWithPath: "/tmp/x.flac"))
        XCTAssertEqual(parsed.blocks.count, 1)
        XCTAssertEqual(parsed.blocks[0].type, FlacBlockType.streamInfo)
        XCTAssertTrue(parsed.blocks[0].isLast)
    }
}
