import XCTest
@testable import MediaTagger

final class MetadataSummaryTests: XCTestCase {
    private var directory: URL!
    private let cover = Data([0xFF, 0xD8, 0xFF, 0xD9])
    private let entries: [(key: String, value: String)] = [
        ("TITLE", "Summary 世界"), ("TRACKNUMBER", "03"), ("TRACKTOTAL", "12"),
        ("ARTIST", "Not needed in the sidebar")
    ]

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent(".summary-fixtures-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    func testFLACSummaryPreservesCommentsAndSkipsPictureAndID3Prefix() throws {
        let picture = FlacPicture(pictureType: 3, mimeType: "image/jpeg", description: "",
                                  width: 1, height: 1, depth: 24, colors: 0, data: cover)
        let bytes = id3Tag() + Data("fLaC".utf8)
            + flacBlock(0, Data(count: 34))
            + flacBlock(6, picture.encode())
            + flacBlock(0x84, VorbisComment(vendor: "test", entries: entries).encode())
        let url = try fixture("sample.flac", bytes)
        let full = try FlacFile.read(url)
        let summary = try FlacFile.read(url, summaryOnly: true)
        XCTAssertEqual(project(summary.vorbisComment.entries), project(full.vorbisComment.entries))
        XCTAssertEqual(summary.blocks.map(\.type), [FlacBlockType.vorbisComment])
        XCTAssertEqual(summary.audioOffset, full.audioOffset)
        XCTAssertTrue(summary.id3Prefix.isEmpty)
        XCTAssertFalse(full.id3Prefix.isEmpty)
        XCTAssertEqual(full.firstPicture?.data, cover)
        XCTAssertNil(summary.firstPicture)
    }

    func testFLACSummaryStillRejectsTruncatedSkippedBlock() throws {
        let url = try fixture("truncated.flac", Data("fLaC".utf8) + Data([0x86, 0, 1, 0]))
        XCTAssertThrowsError(try FlacFile.read(url))
        XCTAssertThrowsError(try FlacFile.read(url, summaryOnly: true))
    }

    func testID3SummaryMatchesV23AndV24WithExtendedHeaders() throws {
        for major: UInt8 in [3, 4] {
            for extended in [false, true] {
                let url = try fixture("sample-\(major)-\(extended).mp3",
                                      id3Tag(major: major, extended: extended))
                let full = try ID3v2File.read(url).decoded()
                let file = try ID3v2File.read(url, summaryOnly: true)
                let summary = file.decoded()
                XCTAssertEqual(project(summary.entries), project(full.entries))
                XCTAssertEqual(file.frames.map(\.id), ["TIT2", "TRCK"])
                XCTAssertEqual(full.cover?.data, cover)
                XCTAssertNil(summary.cover)
                XCTAssertTrue(file.body.isEmpty)
            }
        }
    }

    func testEmbeddedID3SummariesMatchFullReaders() throws {
        let tag = id3Tag(major: 4, extended: true)
        let aiff = try fixture("sample.aiff", iff("FORM", "AIFF", chunk("ID3 ", tag)))
        let dffBody = Data("DSD ".utf8) + chunk("ID3 ", tag, wide: true)
        let dff = try fixture("sample.dff", Data("FRM8".utf8) + integer(dffBody.count, width: 8) + dffBody)
        let dsfHeader = Data("DSD ".utf8) + integer(28, width: 8, little: true)
            + integer(80 + tag.count, width: 8, little: true) + integer(80, width: 8, little: true)
            + Data(count: 52)
        let dsf = try fixture("sample.dsf", dsfHeader + tag)

        let pairs = [
            (try AIFFFile.read(aiff).decoded(), try AIFFFile.read(aiff, summaryOnly: true).decoded()),
            (try DFFFile.read(dff).decoded(), try DFFFile.read(dff, summaryOnly: true).decoded()),
            (try DSFFile.read(dsf).decoded(), try DSFFile.read(dsf, summaryOnly: true).decoded())
        ]
        for (full, summary) in pairs {
            XCTAssertEqual(project(summary.entries), project(full.entries))
            XCTAssertEqual(summary.entries.map(\.key), ["TITLE", "TRACKNUMBER", "TRACKTOTAL"])
            XCTAssertEqual(full.cover?.data, cover)
            XCTAssertNil(summary.cover)
        }
    }

    func testID3SummarySeeksAcrossSparseArtworkWithoutReadingPayload() throws {
        let pictureSize = 64 * 1024 * 1024
        let offset = 64
        let title = frame("TIT2", ID3Frame.encodeText("Summary 世界"), major: 3)
        let track = frame("TRCK", ID3Frame.encodeText("03/12"), major: 3)
        let pictureHeader = Data("APIC".utf8) + integer(pictureSize) + Data([0, 0])
        let tagSize = title.count + pictureHeader.count + pictureSize + track.count
        let url = try fixture("sparse-id3.bin", Data(count: offset)
                              + Data([0x49, 0x44, 0x33, 3, 0, 0]) + syncsafe(tagSize)
                              + title + pictureHeader)
        let payloadStart = offset + 10 + title.count + pictureHeader.count
        let writer = try FileHandle(forWritingTo: url)
        try writer.seek(toOffset: UInt64(payloadStart + pictureSize))
        try writer.write(contentsOf: track)
        try writer.close()

        let source = try FileHandle(forReadingFrom: url)
        defer { try? source.close() }
        let counted = CountingID3Reader(handle: source)
        let tag = try ID3v2File.readSummaryTag(handle: counted, offset: UInt64(offset),
                                             available: UInt64(10 + tagSize))
        let summary = try ID3v2File.parse(tag, url: url).decoded()
        XCTAssertEqual(project(summary.entries), project(entries))
        XCTAssertNil(summary.cover)
        XCTAssertLessThan(counted.bytesRead, 256)
        let pictureRange = UInt64(payloadStart)..<UInt64(payloadStart + pictureSize)
        XCTAssertFalse(counted.ranges.contains { $0.overlaps(pictureRange) })
    }

    func testID3SummaryCancellationPropagatesThroughEmbeddedReaders() async throws {
        let tag = id3Tag()
        let dffBody = Data("DSD ".utf8) + chunk("ID3 ", tag, wide: true)
        let dsfHeader = Data("DSD ".utf8) + integer(28, width: 8, little: true)
            + integer(80 + tag.count, width: 8, little: true)
            + integer(80, width: 8, little: true) + Data(count: 52)
        let urls = [
            try fixture("cancel.mp3", tag),
            try fixture("cancel.aiff", iff("FORM", "AIFF", chunk("ID3 ", tag))),
            try fixture("cancel.dff", Data("FRM8".utf8) + integer(dffBody.count, width: 8) + dffBody),
            try fixture("cancel.dsf", dsfHeader + tag)
        ]
        for url in urls {
            let task = Task.detached {
                withUnsafeCurrentTask { $0?.cancel() }
                switch url.pathExtension {
                case "aiff": _ = try AIFFFile.read(url, summaryOnly: true)
                case "dff": _ = try DFFFile.read(url, summaryOnly: true)
                case "dsf": _ = try DSFFile.read(url, summaryOnly: true)
                default: _ = try ID3v2File.read(url, summaryOnly: true)
                }
            }
            do {
                try await task.value
                XCTFail("Expected cancellation for \(url.pathExtension)")
            } catch {
                XCTAssertTrue(error is CancellationError)
            }
        }
    }

    func testID3SummaryPreservesTruncationAndMalformedFrameBehavior() throws {
        let truncated = try fixture("truncated.mp3",
                                    Data([0x49, 0x44, 0x33, 3, 0, 0]) + syncsafe(100))
        XCTAssertThrowsError(try ID3v2File.read(truncated))
        XCTAssertThrowsError(try ID3v2File.read(truncated, summaryOnly: true))
        let malformedFrames = frame("TIT2", ID3Frame.encodeText("valid"), major: 3)
            + Data("APIC".utf8) + integer(1000) + Data([0, 0])
        let malformed = try fixture("malformed.mp3",
                                    Data([0x49, 0x44, 0x33, 3, 0, 0])
                                    + syncsafe(malformedFrames.count) + malformedFrames)
        XCTAssertEqual(project(try ID3v2File.read(malformed).decoded().entries),
                       project(try ID3v2File.read(malformed, summaryOnly: true).decoded().entries))
        let untagged = try fixture("untagged.mp3", Data([1, 2, 3]))
        XCTAssertTrue(try ID3v2File.read(untagged, summaryOnly: true).frames.isEmpty)
    }

    func testMP4SummaryPreservesStandardAndFreeformTitleTrack() throws {
        let title = atom("©nam", mp4Data(Data("Summary 世界".utf8)))
        let track = atom("trkn", mp4Data(Data([0, 0, 0, 3, 0, 12, 0, 0]), type: 0))
        let art = atom("covr", mp4Data(cover, type: 13))
        // The name may follow data; freeform keys can duplicate standard keys.
        let freeform = atom("----", mp4Data(Data("24".utf8))
                            + atom("name", Data(count: 4) + Data("tracktotal".utf8)))
        let ignored = atom("----", atom("name", Data(count: 4) + Data("ARTIST".utf8))
                           + mp4Data(Data("ignored".utf8)))
        let ilst = atom("ilst", art + title + track + freeform + ignored)
        let url = try fixture("sample.m4a", atom("moov", atom("udta", atom("meta", Data(count: 4) + ilst))))
        let file = try MP4File.read(url)
        let full = file.decoded()
        let summary = file.decoded(summaryOnly: true)
        XCTAssertEqual(project(summary.entries.map { ($0.key, $0.value) }),
                       project(full.entries.map { ($0.key, $0.value) }))
        XCTAssertEqual(summary.entries.map(\.value), ["Summary 世界", "3", "12", "24"])
        XCTAssertEqual(full.cover?.data, cover)
        XCTAssertNil(summary.cover)
    }

    func testMatroskaSummarySkipsAttachmentsBeforeTagsWithAndWithoutSeekHead() throws {
        let tags = matroskaTags()
        let attachedFile = element([0x61, 0xA7],
                                   element([0x46, 0x60], Data("image/jpeg".utf8))
                                   + element([0x46, 0x5C], cover))
        let attachments = element([0x19, 0x41, 0xA4, 0x69], attachedFile)
        for useSeekHead in [false, true] {
            var seekHead = Data()
            if useSeekHead {
                // Fixed-width sizes and offsets make the second pass stable.
                let placeholder = matroskaSeekHead(tags: 0, attachments: 0)
                seekHead = matroskaSeekHead(tags: placeholder.count + attachments.count,
                                           attachments: placeholder.count)
                XCTAssertEqual(seekHead.count, placeholder.count)
            }
            let url = try fixture("sample-\(useSeekHead).mka",
                                  element([0x1A, 0x45, 0xDF, 0xA3], Data())
                                  + element([0x18, 0x53, 0x80, 0x67], seekHead + attachments + tags))
            let full = try MatroskaFile.read(url)
            let summary = try MatroskaFile.read(url, summaryOnly: true)
            XCTAssertEqual(project(summary.entries), project(full.entries))
            XCTAssertEqual(project(summary.entries), project(entries))
            XCTAssertEqual(full.cover?.data, cover)
            XCTAssertNil(summary.cover)
        }
    }

    func testAVISummaryPreservesTrackSlashAndDuplicateTrackIDs() throws {
        let info = Data("INFO".utf8)
            + chunk("ICMT", Data(repeating: 65, count: 4096), little: true)
            + chunk("INAM", Data("Summary 世界\0".utf8), little: true)
            + chunk("IPRT", Data("03/12\0".utf8), little: true)
            + chunk("ITRK", Data("4\0".utf8), little: true)
        let url = try fixture("sample.avi", iff("RIFF", "AVI ", chunk("LIST", info, little: true), little: true))
        let full = try AVIFile.read(url)
        let summary = try AVIFile.read(url, summaryOnly: true)
        XCTAssertEqual(project(summary.entries), project(full.entries))
        XCTAssertEqual(summary.entries.map(\.value), ["Summary 世界", "03/12", "4"])
    }

    private func fixture(_ name: String, _ bytes: Data) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }

    private func project(_ values: [(key: String, value: String)]) -> [String] {
        values.filter { ["TITLE", "TRACKNUMBER", "TRACKTOTAL"].contains($0.key) }
            .map { "\($0.key)=\($0.value)" }
    }

    private func integer(_ value: Int, width: Int = 4, little: Bool = false) -> Data {
        let shifts = little ? Array(0..<width) : Array((0..<width).reversed())
        return Data(shifts.map { UInt8(truncatingIfNeeded: UInt64(value) >> ($0 * 8)) })
    }

    private func syncsafe(_ value: Int) -> Data {
        Data([21, 14, 7, 0].map { UInt8((value >> $0) & 0x7F) })
    }

    private func frame(_ id: String, _ payload: Data, major: UInt8) -> Data {
        Data(id.utf8) + (major >= 4 ? syncsafe(payload.count) : integer(payload.count))
            + Data([0, 0]) + payload
    }

    private func id3Tag(major: UInt8 = 3, extended: Bool = false) -> Data {
        var body = Data()
        if extended {
            body = major >= 4 ? syncsafe(6) + Data([1, 0]) : integer(6) + Data(count: 6)
        }
        body += frame("APIC", ID3Frame.encodeAPIC(data: cover, mime: "image/jpeg"), major: major)
        body += frame("TIT2", ID3Frame.encodeText("Summary 世界"), major: major)
        body += frame("TXXX", ID3Frame.encodeTXXX(description: "TITLE", value: "ignored"), major: major)
        body += frame("TPE1", ID3Frame.encodeText("Not needed in the sidebar"), major: major)
        body += frame("TRCK", ID3Frame.encodeText("03/12"), major: major)
        return Data([0x49, 0x44, 0x33, major, 0, extended ? 0x40 : 0])
            + syncsafe(body.count) + body
    }

    private func flacBlock(_ type: UInt8, _ payload: Data) -> Data {
        Data([type]) + integer(payload.count, width: 3) + payload
    }

    private func chunk(_ id: String, _ payload: Data, wide: Bool = false, little: Bool = false) -> Data {
        Data(id.utf8) + integer(payload.count, width: wide ? 8 : 4, little: little)
            + payload + Data(count: payload.count & 1)
    }

    private func iff(_ id: String, _ type: String, _ children: Data, little: Bool = false) -> Data {
        Data(id.utf8) + integer(4 + children.count, little: little) + Data(type.utf8) + children
    }

    private func atom(_ type: String, _ payload: Data) -> Data {
        integer(8 + payload.count) + type.data(using: .isoLatin1)! + payload
    }

    private func mp4Data(_ payload: Data, type: Int = 1) -> Data {
        atom("data", integer(type) + Data(count: 4) + payload)
    }

    private func element(_ id: [UInt8], _ payload: Data) -> Data {
        Data(id) + integer((1 << 56) | payload.count, width: 8) + payload
    }

    private func matroskaTags() -> Data {
        let names = [("TITLE", "Summary 世界"), ("PART_NUMBER", "03"), ("TOTAL_PARTS", "12")]
        let simpleTags = names.reduce(into: Data()) { result, entry in
            result += element([0x67, 0xC8], element([0x45, 0xA3], Data(entry.0.utf8))
                              + element([0x44, 0x87], Data(entry.1.utf8)))
        }
        return element([0x12, 0x54, 0xC3, 0x67], element([0x73, 0x73], simpleTags))
    }

    private func matroskaSeekHead(tags: Int, attachments: Int) -> Data {
        let targets: [([UInt8], Int)] = [([0x12, 0x54, 0xC3, 0x67], tags),
                                        ([0x19, 0x41, 0xA4, 0x69], attachments)]
        let seeks = targets.reduce(into: Data()) { result, target in
            result += element([0x4D, 0xBB], element([0x53, 0xAB], Data(target.0))
                              + element([0x53, 0xAC], integer(target.1, width: 8)))
        }
        return element([0x11, 0x4D, 0x9B, 0x74], seeks)
    }
}

private final class CountingID3Reader: ID3TagReader {
    private let handle: FileHandle
    var bytesRead = 0
    var ranges: [Range<UInt64>] = []

    init(handle: FileHandle) {
        self.handle = handle
    }

    func seek(toOffset offset: UInt64) throws {
        try handle.seek(toOffset: offset)
    }

    func readData(ofLength length: Int) -> Data {
        let start = handle.offsetInFile
        let data = handle.readData(ofLength: length)
        bytesRead += data.count
        ranges.append(start..<start + UInt64(data.count))
        return data
    }
}
