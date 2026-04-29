import XCTest
@testable import MediaTagger

final class MP4FileTests: XCTestCase {

    private var fileURL: URL!

    override func setUpWithError() throws {
        fileURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MediaTaggerMP4Test-\(UUID().uuidString).m4a")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: - helpers

    /// Build a minimal MP4 with `ftyp`, `mdat` (with two pretend chunks at known
    /// offsets), and a `moov` containing a `trak/mdia/minf/stbl/stco` whose
    /// entries point into mdat. Atom layout is `ftyp` -> `moov` -> `mdat` so the
    /// writer must patch stco when moov size changes.
    private func makeMinimalMP4(mdatPayload: Data, chunkOffsetsInMdat: [UInt32]) -> Data {
        // ftyp
        var ftypBody = Data()
        ftypBody.append(Data("M4A ".utf8))                // major_brand
        ftypBody.append(contentsOf: [0,0,0,0])            // minor
        ftypBody.append(Data("M4A ".utf8))
        ftypBody.append(Data("mp42".utf8))
        ftypBody.append(Data("isom".utf8))
        let ftyp = atom("ftyp", ftypBody)

        // We will fill in stco entries with absolute file offsets once we know layout.
        // First pass: assemble moov assuming placeholder stco entries (zeros) so we
        // can compute moov size and therefore mdat absolute offset.
        let placeholderMoov = buildMoov(stcoEntries: [UInt32](repeating: 0, count: chunkOffsetsInMdat.count))
        // Layout: ftyp, moov (placeholder), mdat
        let mdatStart = UInt32(ftyp.count + placeholderMoov.count)

        // Compute real absolute chunk offsets: mdatStart + 8 (mdat header) + chunk-in-mdat
        let realOffsets = chunkOffsetsInMdat.map { mdatStart + 8 + $0 }
        let moov = buildMoov(stcoEntries: realOffsets)
        precondition(moov.count == placeholderMoov.count, "moov size must be stable")

        var out = Data()
        out.append(ftyp)
        out.append(moov)
        out.append(atom("mdat", mdatPayload))
        return out
    }

    private func buildMoov(stcoEntries: [UInt32]) -> Data {
        // mvhd (minimal full box)
        var mvhd = Data()
        mvhd.append(contentsOf: [0,0,0,0])             // version+flags
        mvhd.append(beU32(0)); mvhd.append(beU32(0))    // creation/mod time
        mvhd.append(beU32(1000))                        // timescale
        mvhd.append(beU32(0))                           // duration
        mvhd.append(beU32(0x00010000))                  // rate
        mvhd.append(contentsOf: [0x01,0x00])            // volume
        mvhd.append(contentsOf: [UInt8](repeating: 0, count: 10))
        // unity matrix (9 * 4 bytes)
        let m: [UInt32] = [0x00010000,0,0, 0,0x00010000,0, 0,0,0x40000000]
        for v in m { mvhd.append(beU32(v)) }
        mvhd.append(Data(repeating: 0, count: 24))     // pre_defined
        mvhd.append(beU32(2))                          // next_track_ID

        // stco
        var stco = Data()
        stco.append(contentsOf: [0,0,0,0])
        stco.append(beU32(UInt32(stcoEntries.count)))
        for o in stcoEntries { stco.append(beU32(o)) }
        let stcoAtom = atom("stco", stco)

        // Build stbl > minf > mdia > trak > moov
        let stbl = atom("stbl", stcoAtom)
        let minf = atom("minf", stbl)
        let mdia = atom("mdia", minf)
        let trak = atom("trak", mdia)

        var moovBody = Data()
        moovBody.append(atom("mvhd", mvhd))
        moovBody.append(trak)
        return atom("moov", moovBody)
    }

    private func atom(_ type: String, _ payload: Data) -> Data {
        var d = Data()
        d.append(beU32(UInt32(8 + payload.count)))
        d.append(Data(type.utf8))
        d.append(payload)
        return d
    }

    private func beU32(_ v: UInt32) -> Data {
        Data([UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF),
              UInt8(v >> 8  & 0xFF), UInt8(v       & 0xFF)])
    }

    // MARK: - tests

    func testWriteCreatesIlstAndPreservesMdat() throws {
        let mdatPayload = Data((0..<256).map { UInt8($0 & 0xFF) })
        let mp4 = makeMinimalMP4(mdatPayload: mdatPayload, chunkOffsetsInMdat: [0, 64, 128])
        try mp4.write(to: fileURL)

        try MP4File.write(url: fileURL, entries: [
            ("TITLE", "Hello M4A"),
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

        let parsed = try MP4File.read(fileURL)
        let (entries, cover) = parsed.decoded()
        XCTAssertNil(cover)
        let dict = Dictionary(entries.map { ($0.key, $0.value) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(dict["TITLE"], "Hello M4A")
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

        // mdat payload is intact somewhere in the file.
        let raw = try Data(contentsOf: fileURL)
        XCTAssertNotNil(raw.range(of: mdatPayload))
    }

    func testStcoOffsetsArePatchedAfterWrite() throws {
        let mdatPayload = Data((0..<256).map { UInt8($0 & 0xFF) })
        let chunkOffsets: [UInt32] = [0, 64, 128]
        let mp4 = makeMinimalMP4(mdatPayload: mdatPayload, chunkOffsetsInMdat: chunkOffsets)
        try mp4.write(to: fileURL)

        try MP4File.write(url: fileURL,
                         entries: [("TITLE", "ABC"), ("ARTIST", "XYZ")],
                         cover: nil)

        // Re-locate stco in the rewritten file and verify each offset still
        // points to the same byte that was originally pointed at.
        let raw = try Data(contentsOf: fileURL)
        let stcoRange = raw.range(of: Data("stco".utf8))!
        // 4 bytes back is the size, ahead 4 bytes version/flags, then count, then entries.
        var p = stcoRange.upperBound + 4   // skip version+flags
        let count = Int(beReadU32(raw, p)); p += 4
        XCTAssertEqual(count, chunkOffsets.count)
        for i in 0..<count {
            let off = Int(beReadU32(raw, p)); p += 4
            // Bytes at the new offset should equal the bytes that used to be there.
            let expectedByte = UInt8(Int(chunkOffsets[i]) & 0xFF)
            XCTAssertEqual(raw[off], expectedByte,
                           "Chunk \(i) offset not patched correctly: at byte \(off) got 0x\(String(raw[off], radix: 16)) expected 0x\(String(expectedByte, radix: 16))")
        }
    }

    func testCoverArtRoundTrip() throws {
        let mdatPayload = Data((0..<32).map { _ in UInt8(0xAB) })
        let mp4 = makeMinimalMP4(mdatPayload: mdatPayload, chunkOffsetsInMdat: [0])
        try mp4.write(to: fileURL)

        let png = Data([
            0x89,0x50,0x4E,0x47,0x0D,0x0A,0x1A,0x0A,
            0x00,0x00,0x00,0x0D,0x49,0x48,0x44,0x52,
            0x00,0x00,0x00,0x01,0x00,0x00,0x00,0x01,
            0x08,0x06,0x00,0x00,0x00,0x1F,0x15,0xC4,0x89,
            0x00,0x00,0x00,0x0D,0x49,0x44,0x41,0x54,
            0x78,0x9C,0x62,0x00,0x01,0x00,0x00,0x05,0x00,0x01,0x0D,0x0A,0x2D,0xB4,
            0x00,0x00,0x00,0x00,0x49,0x45,0x4E,0x44,0xAE,0x42,0x60,0x82
        ])
        try MP4File.write(url: fileURL,
                         entries: [("TITLE", "with art")],
                         cover: MP4File.Cover(data: png, mime: "image/png"))

        let (entries, cover) = try MP4File.read(fileURL).decoded()
        XCTAssertEqual(entries.first(where: { $0.key == "TITLE" })?.value, "with art")
        XCTAssertEqual(cover?.mime, "image/png")
        XCTAssertEqual(cover?.data, png)
    }

    func testRewriteReplacesPreviousTags() throws {
        let mdatPayload = Data((0..<32).map { _ in UInt8(0xCD) })
        let mp4 = makeMinimalMP4(mdatPayload: mdatPayload, chunkOffsetsInMdat: [0])
        try mp4.write(to: fileURL)

        try MP4File.write(url: fileURL, entries: [("TITLE", "first")], cover: nil)
        try MP4File.write(url: fileURL, entries: [("TITLE", "second")], cover: nil)

        let (entries, _) = try MP4File.read(fileURL).decoded()
        let titles = entries.filter { $0.key == "TITLE" }
        XCTAssertEqual(titles.count, 1)
        XCTAssertEqual(titles.first?.value, "second")
    }

    func testMetadataServiceM4ARoundTrip() throws {
        let mdatPayload = Data((0..<32).map { _ in UInt8(0x42) })
        let mp4 = makeMinimalMP4(mdatPayload: mdatPayload, chunkOffsetsInMdat: [0])
        try mp4.write(to: fileURL)

        let svc = MetadataService()
        var md = try svc.read(fileURL)
        md.setTag("TITLE", "From Service")
        md.setTag("TRACKNUMBER", "5")
        md.setTag("TRACKTOTAL", "10")
        try svc.write(md, to: fileURL)

        let again = try svc.read(fileURL)
        XCTAssertEqual(again.title, "From Service")
        XCTAssertEqual(again.first("TRACKNUMBER"), "5")
        XCTAssertEqual(again.first("TRACKTOTAL"), "10")
    }

    private func beReadU32(_ d: Data, _ p: Int) -> UInt32 {
        return (UInt32(d[p]) << 24) | (UInt32(d[p+1]) << 16) |
               (UInt32(d[p+2]) << 8) |  UInt32(d[p+3])
    }
}
