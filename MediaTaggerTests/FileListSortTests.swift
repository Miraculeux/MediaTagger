import XCTest
@testable import MediaTagger

final class FileListSortTests: XCTestCase {
    private func row(_ name: String, track: String, title: String? = nil) -> FileListRow {
        FileListRow(file: MediaFile(id: URL(fileURLWithPath: "/music/\(name).flac")),
                    title: title, track: track)
    }

    private func sortedNames(_ rows: [FileListRow], by field: FileListSortField = .track,
                             ascending: Bool = true) -> [String] {
        rows.sorted { $0.orderedBefore($1, by: field, ascending: ascending) }
            .map { $0.file.url.deletingPathExtension().lastPathComponent }
    }

    func testTrackSortUsesNumbersInBothDirections() {
        let rows = [row("ten", track: "10"), row("two", track: "2"), row("one", track: "01")]
        XCTAssertEqual(sortedNames(rows), ["one", "two", "ten"])
        XCTAssertEqual(sortedNames(rows, ascending: false), ["ten", "two", "one"])
    }

    func testTrackTotalAndLeadingZerosDoNotAffectOrder() {
        let rows = [row("b", track: "02 / 3"), row("a", track: " 2 / 99 "),
                    row("c", track: "10 / 12")]
        XCTAssertEqual(sortedNames(rows), ["a", "b", "c"])
        XCTAssertEqual(sortedNames(rows, ascending: false), ["c", "b", "a"])
    }

    func testMissingTrackUsesConsistentEmptyValueOrdering() {
        let rows = [row("tagged", track: "1"), row("b", track: ""),
                    row("a", track: "   ")]
        XCTAssertEqual(sortedNames(rows), ["a", "b", "tagged"])
        XCTAssertEqual(sortedNames(rows, ascending: false), ["tagged", "b", "a"])
    }

    func testEqualTrackAndFilenameUsePathTieBreaker() {
        let a = FileListRow(file: MediaFile(id: URL(fileURLWithPath: "/a/song.flac")),
                            title: nil, track: "2")
        let b = FileListRow(file: MediaFile(id: URL(fileURLWithPath: "/b/song.flac")),
                            title: nil, track: "02")
        XCTAssertTrue(a.orderedBefore(b, by: .track, ascending: true))
        XCTAssertFalse(b.orderedBefore(a, by: .track, ascending: true))
        XCTAssertTrue(b.orderedBefore(a, by: .track, ascending: false))
        XCTAssertFalse(a.orderedBefore(a, by: .track, ascending: true))
    }

    func testFileAndTitleSortRemainUnchanged() {
        let rows = [row("file10", track: "1", title: "Alpha"),
                    row("file2", track: "3", title: "Beta"),
                    row("file1", track: "2", title: "Alpha")]
        XCTAssertEqual(sortedNames(rows, by: .file), ["file1", "file2", "file10"])
        XCTAssertEqual(sortedNames(rows, by: .title), ["file1", "file10", "file2"])
        XCTAssertEqual(sortedNames(rows, by: .title, ascending: false), ["file2", "file10", "file1"])
    }

    func testUpdatedTrackValuesAreUsedWithoutChangingFileIdentity() {
        let original = row("a", track: "")
        let other = row("b", track: "2")
        XCTAssertEqual(sortedNames([original, other]), ["a", "b"])
        let updated = row("a", track: "10")
        XCTAssertEqual(updated.id, original.id)
        XCTAssertEqual(sortedNames([updated, other]), ["b", "a"])
    }
}
