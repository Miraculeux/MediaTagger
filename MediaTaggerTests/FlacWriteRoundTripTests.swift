import XCTest
@testable import MediaTagger

/// End-to-end save tests against a synthetic FLAC file on disk.
/// Mirrors what the UI does: read -> modify metadata -> write -> re-read.
final class FlacWriteRoundTripTests: XCTestCase {

    private var fileURL: URL!

    override func setUpWithError() throws {
        fileURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MediaTaggerTest-\(UUID().uuidString).flac")
        try makeSyntheticFlac().write(to: fileURL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: fileURL)
    }

    func testWriteThenReadStandardFields() throws {
        // 1. Read the file.
        var file = try FlacFile.read(fileURL)
        // 2. Replace Vorbis comments.
        file.setVorbisComment(VorbisComment(
            vendor: "MediaTagger",
            entries: [
                ("TITLE", "Hello"),
                ("ARTIST", "Tester"),
                ("TRACKNUMBER", "3"),
            ]
        ))
        // 3. Save.
        try file.write()
        // 4. Re-read and confirm.
        let reread = try FlacFile.read(fileURL)
        let vc = reread.vorbisComment
        XCTAssertEqual(vc.entries.first(where: { $0.key == "TITLE" })?.value, "Hello")
        XCTAssertEqual(vc.entries.first(where: { $0.key == "ARTIST" })?.value, "Tester")
        XCTAssertEqual(vc.entries.first(where: { $0.key == "TRACKNUMBER" })?.value, "3")
    }

    func testWriteThroughMetadataService() throws {
        let svc = MetadataService()
        var md = try svc.read(fileURL)
        md.setTag("TITLE", "Brand New Title")
        md.setTag("TRACKNUMBER", "07")
        try svc.write(md, to: fileURL)

        let again = try svc.read(fileURL)
        XCTAssertEqual(again.title, "Brand New Title")
        XCTAssertEqual(again.first("TRACKNUMBER"), "07")
    }

    func testGrowingMetadataTriggersRewriteAndStillReadable() throws {
        let svc = MetadataService()
        var md = try svc.read(fileURL)
        // Ridiculously long value to force the metadata area to grow past padding.
        let bigValue = String(repeating: "x", count: 50_000)
        md.setTag("COMMENT", bigValue)
        try svc.write(md, to: fileURL)

        let again = try svc.read(fileURL)
        XCTAssertEqual(again.first("COMMENT")?.count, 50_000)

        // Audio data preserved.
        let raw = try Data(contentsOf: fileURL)
        // Look for the marker we placed at the end of the synthetic audio frames.
        XCTAssertNotNil(raw.range(of: Data("AUDIOEND".utf8)))
    }

    // MARK: - Synthetic FLAC helpers

    /// Builds a minimal-but-valid FLAC byte sequence:
    ///   "fLaC" + STREAMINFO (last=0) + VORBIS_COMMENT (last=1) + fake audio bytes
    private func makeSyntheticFlac() -> Data {
        var data = Data([0x66, 0x4C, 0x61, 0x43])
        // STREAMINFO (type 0), 34 zero bytes, last=0
        data.append(0x00)
        data.append(contentsOf: [0x00, 0x00, 0x22])
        data.append(Data(count: 34))
        // VORBIS_COMMENT (type 4), last=1
        let vc = VorbisComment(vendor: "synthetic", entries: [("TITLE", "Original")])
        let vcData = vc.encode()
        data.append(0x80 | 0x04) // last + type 4
        data.append(UInt8((vcData.count >> 16) & 0xFF))
        data.append(UInt8((vcData.count >> 8) & 0xFF))
        data.append(UInt8(vcData.count & 0xFF))
        data.append(vcData)
        // "Audio" bytes — anything; we just need something past audioOffset.
        data.append(Data(repeating: 0xAB, count: 256))
        data.append(Data("AUDIOEND".utf8))
        return data
    }
}
