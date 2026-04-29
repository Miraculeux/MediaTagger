import XCTest
@testable import MediaTagger

final class BatchOperationsTests: XCTestCase {

    func testFilenameCleaner_stripsTrackNumberAndExtension() {
        let opts = FilenameCleanupOptions()
        XCTAssertEqual(FilenameCleaner.title(from: "01 Hello.flac", options: opts), "Hello")
        XCTAssertEqual(FilenameCleaner.title(from: "01-Hello World.flac", options: opts), "Hello World")
        XCTAssertEqual(FilenameCleaner.title(from: "12.Hello.flac", options: opts), "Hello")
        XCTAssertEqual(FilenameCleaner.title(from: "1-02 Hello.flac", options: opts), "Hello")
    }

    func testFilenameCleaner_underscoresAndWhitespace() {
        let s = FilenameCleaner.title(from: "03_-_my___song.mp3")
        XCTAssertEqual(s, "my song")
    }

    func testFilenameCleaner_disabledOptions() {
        var opts = FilenameCleanupOptions()
        opts.stripLeadingTrackNumber = false
        opts.underscoresToSpaces = false
        XCTAssertEqual(FilenameCleaner.title(from: "01_Hello.flac", options: opts), "01_Hello")
    }

    func testTrackNumberFormatting() {
        let opts = TrackNumberingOptions(startAt: 1, writeTotal: true, zeroPadWidth: 2)
        XCTAssertEqual(opts.formatted(1), "01")
        XCTAssertEqual(opts.formatted(12), "12")
        XCTAssertEqual(TrackNumberingOptions(zeroPadWidth: 0).formatted(7), "7")
    }

    func testBatchPlanAppliesTagsAndRenumber() {
        var md = MediaMetadata()
        var plan = BatchPlan()
        plan.album = "My Album"
        plan.titleFromFilename = FilenameCleanupOptions()
        plan.renumberTracks = TrackNumberingOptions(startAt: 1, writeTotal: true, zeroPadWidth: 2)
        let file = MediaFile(id: URL(fileURLWithPath: "/tmp/03 Hello.flac"))
        plan.apply(to: &md, file: file, indexInSelection: 2, totalInSelection: 10)

        XCTAssertEqual(md.first("ALBUM"), "My Album")
        XCTAssertEqual(md.first("TITLE"), "Hello")
        XCTAssertEqual(md.first("TRACKNUMBER"), "03")
        XCTAssertEqual(md.first("TRACKTOTAL"), "10")
    }

    func testSetTagReplacesDuplicates() {
        var md = MediaMetadata(tags: [
            .init(key: "ARTIST", value: "Old"),
            .init(key: "artist", value: "Older"),
        ])
        md.setTag("ARTIST", "New")
        let artists = md.tags.filter { $0.key.caseInsensitiveCompare("ARTIST") == .orderedSame }
        XCTAssertEqual(artists.count, 1)
        XCTAssertEqual(artists.first?.value, "New")
    }

    func testSetTagNilRemoves() {
        var md = MediaMetadata(tags: [.init(key: "ALBUM", value: "X")])
        md.setTag("album", nil)
        XCTAssertNil(md.first("ALBUM"))
    }

    func testHasAnyOperation() {
        XCTAssertFalse(BatchPlan().hasAnyOperation)
        var p = BatchPlan(); p.album = "x"
        XCTAssertTrue(p.hasAnyOperation)
    }
}
