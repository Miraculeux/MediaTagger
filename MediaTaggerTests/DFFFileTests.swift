import XCTest
@testable import MediaTagger

final class DFFFileTests: XCTestCase {

    private var fileURL: URL!
    /// Pretend DSD audio body — odd length to exercise the pad-byte logic.
    private let dsdAudio = Data((0..<33).map { UInt8($0 & 0xFF) })

    override func setUpWithError() throws {
        fileURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MediaTaggerDFFTest-\(UUID().uuidString).dff")
        try makeMinimalDFF().write(to: fileURL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Build a tiny DSDIFF: FRM8 { "DSD " + FVER + DSD chunk } with no ID3 yet.
    private func makeMinimalDFF() -> Data {
        // FVER chunk: 4 bytes payload (version 1.5.0.0).
        let fver = chunk(id: "FVER", payload: Data([0x01, 0x05, 0x00, 0x00]))
        // DSD audio chunk (odd length ⇒ 1 pad byte).
        let dsd = chunk(id: "DSD ", payload: dsdAudio)

        var inner = Data()
        inner.append(Data("DSD ".utf8))     // form type
        inner.append(fver)
        inner.append(dsd)

        var out = Data()
        out.append(Data("FRM8".utf8))
        out.append(beU64(UInt64(inner.count)))
        out.append(inner)
        return out
    }

    private func chunk(id: String, payload: Data) -> Data {
        var d = Data()
        d.append(Data(id.utf8))
        d.append(beU64(UInt64(payload.count)))
        d.append(payload)
        if payload.count & 1 == 1 { d.append(0) }
        return d
    }

    private func beU64(_ v: UInt64) -> Data {
        var out = [UInt8](repeating: 0, count: 8)
        for i in 0..<8 { out[i] = UInt8((v >> (56 - i * 8)) & 0xFF) }
        return Data(out)
    }

    private func readBEU64(_ d: Data, _ p: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<8 { v = (v << 8) | UInt64(d[p+i]) }
        return v
    }

    // MARK: - tests

    func testWriteCreatesID3AndPreservesAudio() throws {
        try DFFFile.write(url: fileURL, entries: [
            ("TITLE", "Hello DFF"),
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

        let parsed = try DFFFile.read(fileURL)
        let (entries, _) = parsed.decoded()
        let dict = Dictionary(entries.map { ($0.key, $0.value) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(dict["TITLE"], "Hello DFF")
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
        try DFFFile.write(url: fileURL,
                         entries: [("TITLE", "with art")],
                         cover: (png, "image/png"))
        let (_, cover) = try DFFFile.read(fileURL).decoded()
        XCTAssertEqual(cover?.mime, "image/png")
        XCTAssertEqual(cover?.data, png)
    }

    func testRewriteReplacesPreviousID3Chunk() throws {
        try DFFFile.write(url: fileURL, entries: [("TITLE", "first")], cover: nil)
        try DFFFile.write(url: fileURL, entries: [("TITLE", "second")], cover: nil)

        let (entries, _) = try DFFFile.read(fileURL).decoded()
        let titles = entries.filter { $0.key == "TITLE" }
        XCTAssertEqual(titles.count, 1)
        XCTAssertEqual(titles.first?.value, "second")

        // Verify exactly one ID3 chunk in the file.
        let raw = try Data(contentsOf: fileURL)
        var count = 0
        var p = 16
        while p + 12 <= raw.count {
            let id = String(data: raw.subdata(in: p..<p+4), encoding: .ascii) ?? ""
            let size = Int(readBEU64(raw, p + 4))
            if id == "ID3 " { count += 1 }
            p += 12 + size + (size & 1)
        }
        XCTAssertEqual(count, 1)
    }

    func testFRM8SizeIsCorrectAfterWrite() throws {
        try DFFFile.write(url: fileURL,
                         entries: [("TITLE", "size-check")], cover: nil)
        let raw = try Data(contentsOf: fileURL)
        let frm8Size = readBEU64(raw, 4)
        // FRM8 size counts everything after the 12-byte header.
        XCTAssertEqual(Int(frm8Size), raw.count - 12)
    }

    func testMetadataServiceDFFRoundTrip() throws {
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
