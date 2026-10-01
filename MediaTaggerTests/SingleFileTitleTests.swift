import XCTest
@testable import MediaTagger

final class SingleFileTitleTests: XCTestCase {
    private var directory: URL!
    private let audio = Data("FAKEMP3DATA".utf8)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    @MainActor
    private func makeState(
        name: String = "01_old_name.MP3", title: String? = "Original",
        writer: (@Sendable (MediaMetadata, URL) throws -> Void)? = nil
    ) throws -> AppState {
        let file = MediaFile(id: directory.appendingPathComponent(name))
        try audio.write(to: file.url)
        let state = AppState(metadataWriter: writer ?? { try MetadataService().write($0, to: $1) })
        state.selectedFolder = directory
        state.files = [file]
        state.selectedFile = file
        state.selectedFileIDs = [file.id]
        var metadata = MediaMetadata(tags: [
            .init(key: "ARTIST", value: "Artist"), .init(key: "TRACKNUMBER", value: "03")
        ])
        metadata.setTag(file.isImage ? "IPTC:ObjectName" : "TITLE", title)
        state.metadata = metadata
        return state
    }

    @MainActor
    func testFilenameToTitleStagesEditUntilSaveAndPreservesOtherTags() async throws {
        let state = try makeState()
        let url = try XCTUnwrap(state.selectedFile?.url)
        state.setTitleFromFilename()
        XCTAssertEqual(state.metadata?.title, "old name")
        XCTAssertEqual(state.metadata?.artist, "Artist")
        XCTAssertTrue(state.isDirty)
        XCTAssertEqual(try Data(contentsOf: url), audio)
        await state.saveCurrent()
        let saved = try await MetadataService().read(url)
        XCTAssertEqual(saved.title, "old name")
        XCTAssertEqual(saved.artist, "Artist")
        XCTAssertFalse(state.isDirty)
        XCTAssertNil(state.lastError)
    }

    @MainActor
    func testTitleToFilenameIsStagedAndSavePersistsMetadataAndUpdatesURLs() async throws {
        let state = try makeState(title: "Song")
        let oldURL = try XCTUnwrap(state.selectedFile?.url)
        state.titles[oldURL] = "Original"
        state.tracks[oldURL] = "03"
        state.advancedSearchHits = [.init(url: oldURL, title: "Song", artist: "Artist", album: nil)]
        state.setFilenameFromTitleOnSave(true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldURL.path))
        XCTAssertFalse(state.isDirty)
        let newURL = directory.appendingPathComponent("Song.MP3")
        XCTAssertFalse(FileManager.default.fileExists(atPath: newURL.path))
        await state.saveCurrent()
        XCTAssertNil(state.lastError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: newURL.path))
        XCTAssertEqual(state.selectedFile?.url, newURL)
        XCTAssertEqual(state.selectedFileIDs, [newURL])
        XCTAssertEqual(state.files.map(\.url), [newURL])
        XCTAssertEqual(state.advancedSearchHits?.first?.url, newURL)
        XCTAssertNil(state.titles[oldURL])
        XCTAssertNil(state.tracks[oldURL])
        XCTAssertEqual(state.titles[newURL], "Song")
        XCTAssertEqual(state.tracks[newURL], "03")
        XCTAssertFalse(state.filenameFromTitleOnSave)
        let saved = try await MetadataService().read(newURL)
        XCTAssertEqual(saved.title, "Song")
        XCTAssertEqual(saved.artist, "Artist")
        XCTAssertNotNil(try Data(contentsOf: newURL).range(of: audio))
    }

    @MainActor
    func testRenameUsesTitleAtSaveTimeAndCanBeCancelled() async throws {
        let state = try makeState(title: "First")
        let oldURL = try XCTUnwrap(state.selectedFile?.url)
        state.setFilenameFromTitleOnSave(true)
        state.setFilenameFromTitleOnSave(false)
        await state.saveCurrent()
        XCTAssertEqual(state.selectedFile?.url, oldURL)
        state.setFilenameFromTitleOnSave(true)
        state.setStandardTag("TITLE", "Last")
        await state.saveCurrent()
        XCTAssertEqual(state.selectedFile?.name, "Last.MP3")
        XCTAssertFalse(state.isDirty)
    }

    @MainActor
    func testRenameSanitizesTitlePreservesExtensionAndAvoidsCollisions() async throws {
        let state = try makeState(title: "  A/B:C\\D \n Song\u{0000}  ")
        let collision = directory.appendingPathComponent("A-B-C-D Song.MP3")
        let collisionTwo = directory.appendingPathComponent("A-B-C-D Song (2).MP3")
        let original = Data("DO NOT OVERWRITE".utf8)
        try original.write(to: collision)
        try original.write(to: collisionTwo)
        state.setFilenameFromTitleOnSave(true)
        await state.saveCurrent()
        XCTAssertNil(state.lastError)
        XCTAssertEqual(state.selectedFile?.name, "A-B-C-D Song (3).MP3")
        XCTAssertEqual(try Data(contentsOf: collision), original)
        XCTAssertEqual(try Data(contentsOf: collisionTwo), original)
    }

    @MainActor
    func testUnchangedFilenameDoesNotGetCollisionSuffix() async throws {
        let state = try makeState(name: "Song.MP3", title: "Song")
        let oldURL = state.selectedFile?.url
        state.setFilenameFromTitleOnSave(true)
        await state.saveCurrent()
        XCTAssertNil(state.lastError)
        XCTAssertEqual(state.selectedFile?.url, oldURL)
        XCTAssertFalse(state.filenameFromTitleOnSave)
    }

    @MainActor
    func testInvalidTitleReportsErrorWithoutWritingAndKeepsRenamePending() async throws {
        for title in ["", " \n\u{0000}", ".", ".."] {
            let state = try makeState(title: title, writer: { _, _ in XCTFail("Must not write an invalid rename") })
            state.setFilenameFromTitleOnSave(true)
            await state.saveCurrent()
            XCTAssertNotNil(state.lastError)
            XCTAssertTrue(state.filenameFromTitleOnSave)
            XCTAssertFalse(state.isSaving)
        }
    }

    @MainActor
    func testWriterFailureDoesNotRenameAndKeepsPendingRequest() async throws {
        let state = try makeState(title: "Song", writer: { _, _ in
            throw NSError(domain: "SaveTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "Write failed"])
        })
        let oldURL = try XCTUnwrap(state.selectedFile?.url)
        state.setFilenameFromTitleOnSave(true)
        await state.saveCurrent()
        XCTAssertEqual(state.lastError, "Write failed")
        XCTAssertTrue(state.filenameFromTitleOnSave)
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("Song.MP3").path))
        XCTAssertEqual(state.selectedFile?.url, oldURL)
    }

    @MainActor
    func testRenameFailureReportsErrorAndKeepsPendingRequest() async throws {
        let state = try makeState(title: "Song", writer: { _, url in
            try FileManager.default.removeItem(at: url)
        })
        let oldURL = state.selectedFile?.url
        state.setFilenameFromTitleOnSave(true)
        await state.saveCurrent()
        XCTAssertNotNil(state.lastError)
        XCTAssertTrue(state.filenameFromTitleOnSave)
        XCTAssertEqual(state.selectedFile?.url, oldURL)
    }

    @MainActor
    func testSelectionChangesDiscardPendingRenameAndStaleActionsAreRejected() throws {
        let state = try makeState()
        state.setFilenameFromTitleOnSave(true)
        let other = MediaFile(id: directory.appendingPathComponent("Other.mp3"))
        state.files.append(other)
        state.setSelection([other.id])
        XCTAssertFalse(state.filenameFromTitleOnSave)
        state.setTitleFromFilename()
        XCTAssertNotNil(state.lastError)
        state.setFilenameFromTitleOnSave(true)
        XCTAssertFalse(state.filenameFromTitleOnSave)
        state.setSelection([other.id, state.files[0].id])
        XCTAssertFalse(state.canUseFilenameActions)
    }

    @MainActor
    func testImageUsesIPTCTitleInBothDirections() async throws {
        let state = try makeState(name: "01_old_photo.JPG", title: "Original", writer: { md, _ in
            XCTAssertEqual(md.first("IPTC:ObjectName"), "old photo")
            XCTAssertNil(md.title)
        })
        state.setTitleFromFilename()
        XCTAssertEqual(state.metadata?.first("IPTC:ObjectName"), "old photo")
        XCTAssertNil(state.metadata?.title)
        state.setFilenameFromTitleOnSave(true)
        await state.saveCurrent()
        XCTAssertNil(state.lastError)
        XCTAssertEqual(state.selectedFile?.name, "old photo.JPG")
    }

    @MainActor
    func testEditsDuringSaveRemainDirtyAfterRename() async throws {
        let started = expectation(description: "Write started")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let state = try makeState(title: "Saved", writer: { md, url in
            started.fulfill()
            XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
            try MetadataService().write(md, to: url)
        })
        state.setFilenameFromTitleOnSave(true)
        let save = Task { await state.saveCurrent() }
        await fulfillment(of: [started], timeout: 3)
        state.setStandardTag("TITLE", "Edited during save")
        release.signal()
        await save.value
        XCTAssertEqual(state.selectedFile?.name, "Saved.MP3")
        XCTAssertEqual(state.metadata?.title, "Edited during save")
        XCTAssertTrue(state.isDirty)
        XCTAssertFalse(state.filenameFromTitleOnSave)
    }

    @MainActor
    func testNavigationDuringSaveDoesNotRenameNewSelection() async throws {
        let started = expectation(description: "Write started")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let state = try makeState(title: "Saved", writer: { md, url in
            started.fulfill()
            XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
            try MetadataService().write(md, to: url)
        })
        state.setFilenameFromTitleOnSave(true)
        let save = Task { await state.saveCurrent() }
        await fulfillment(of: [started], timeout: 3)
        let other = MediaFile(id: directory.appendingPathComponent("Other.mp3"))
        state.files.append(other)
        state.setSelection([other.id])
        release.signal()
        await save.value
        XCTAssertEqual(state.selectedFileIDs, [other.id])
        XCTAssertFalse(state.filenameFromTitleOnSave)
        XCTAssertTrue(state.files.contains { $0.name == "Saved.MP3" })
        XCTAssertTrue(state.files.contains { $0.id == other.id })
    }

    @MainActor
    func testReselectionDuringRenameFollowsNewURLBeforeAndAfterDebounce() async throws {
        for waitForDebounce in [false, true] {
            let started = expectation(description: "Write started")
            let release = DispatchSemaphore(value: 0)
            defer { release.signal() }
            let state = try makeState(title: "Saved", writer: { md, url in
                started.fulfill()
                XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
                try MetadataService().write(md, to: url)
            })
            let oldURL = try XCTUnwrap(state.selectedFile?.url)
            state.setFilenameFromTitleOnSave(true)
            let save = Task { await state.saveCurrent() }
            await fulfillment(of: [started], timeout: 3)
            state.setSelection([])
            state.setSelection([oldURL])
            if waitForDebounce {
                try await Task.sleep(for: .milliseconds(150))
                XCTAssertTrue(state.isLoadingMetadata)
            }
            release.signal()
            await save.value
            for _ in 0..<100 {
                if !state.isLoadingMetadata { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertFalse(state.isLoadingMetadata)
            XCTAssertNil(state.lastError)
            let newURL = try XCTUnwrap(state.selectedFile?.url)
            XCTAssertNotEqual(newURL, oldURL)
            XCTAssertTrue(newURL.lastPathComponent.hasPrefix("Saved"))
            XCTAssertEqual(state.selectedFileIDs, [newURL])
            XCTAssertEqual(state.metadata?.title, "Saved")
            XCTAssertFalse(state.filenameFromTitleOnSave)
        }
    }

    @MainActor
    func testFolderChangeDiscardsPendingRename() throws {
        let state = try makeState()
        state.setFilenameFromTitleOnSave(true)
        let emptyFolder = directory.appendingPathComponent("Empty", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyFolder, withIntermediateDirectories: true)
        state.loadFiles(in: emptyFolder)
        XCTAssertFalse(state.filenameFromTitleOnSave)
        XCTAssertFalse(state.canUseFilenameActions)
    }

    @MainActor
    func testBatchRenameStillUsesSharedCleanupAndCollisionRules() async throws {
        let state = try makeState(title: "Song/Title")
        let file = try XCTUnwrap(state.selectedFile)
        try MetadataService().write(try XCTUnwrap(state.metadata), to: file.url)
        let collision = directory.appendingPathComponent("Song-Title.MP3")
        try audio.write(to: collision)
        var plan = BatchPlan()
        plan.filenameFromTitle = true
        state.applyBatch(plan)
        for _ in 0..<100 {
            if !state.batchInProgress { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(state.batchInProgress)
        XCTAssertNil(state.lastError)
        XCTAssertEqual(state.selectedFile?.name, "Song-Title (2).MP3")
        XCTAssertEqual(state.selectedFileIDs, [try XCTUnwrap(state.selectedFile?.url)])
        XCTAssertEqual(try Data(contentsOf: collision), audio)
    }
}
