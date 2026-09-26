import XCTest
@testable import MediaTagger

final class AppStateSaveTests: XCTestCase {
    @MainActor
    private func makeState(
        writer: @escaping @Sendable (MediaMetadata, URL) throws -> Void
    ) -> AppState {
        let state = AppState(metadataWriter: writer)
        let file = MediaFile(id: URL(fileURLWithPath: "/tmp/save-test.flac"))
        state.files = [file]
        state.selectedFolder = file.url.deletingLastPathComponent()
        state.selectedFile = file
        state.selectedFileIDs = [file.id]
        state.metadata = MediaMetadata(tags: [.init(key: "TITLE", value: "Original")])
        state.isDirty = true
        return state
    }

    @MainActor
    func testSaveRunsOffMainThreadAndClearsUnchangedEdits() async {
        let started = expectation(description: "Background write started")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let state = makeState { md, _ in
            XCTAssertFalse(Thread.isMainThread)
            XCTAssertEqual(md.title, "Original")
            started.fulfill()
            XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
        }
        let save = Task { await state.saveCurrent() }
        await fulfillment(of: [started], timeout: 3)
        XCTAssertTrue(state.isSaving)
        XCTAssertTrue(state.isDirty)
        release.signal()
        await save.value
        XCTAssertFalse(state.isSaving)
        XCTAssertFalse(state.isDirty)
        XCTAssertNil(state.lastError)
        XCTAssertEqual(state.titles[state.selectedFile!.url], "Original")
    }

    @MainActor
    func testEditsDuringSaveRemainDirty() async {
        let started = expectation(description: "Background write started")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let state = makeState { _, _ in
            started.fulfill()
            XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
        }
        let save = Task { await state.saveCurrent() }
        await fulfillment(of: [started], timeout: 3)
        state.updateTag(id: state.metadata!.tags[0].id, value: "New edit")
        release.signal()
        await save.value
        XCTAssertTrue(state.isDirty)
        XCTAssertEqual(state.metadata?.title, "New edit")
        XCTAssertEqual(state.titles[state.selectedFile!.url], "Original")
    }

    @MainActor
    func testSelectionChangeDuringSaveDoesNotClearNewFileEdits() async {
        let started = expectation(description: "Background write started")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let state = makeState { _, _ in
            started.fulfill()
            XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
        }
        let save = Task { await state.saveCurrent() }
        await fulfillment(of: [started], timeout: 3)
        let next = MediaFile(id: URL(fileURLWithPath: "/tmp/next.flac"))
        state.selectedFile = next
        state.selectedFileIDs = [next.id]
        state.metadata = MediaMetadata(tags: [.init(key: "TITLE", value: "Next edit")])
        state.isDirty = true
        release.signal()
        await save.value
        XCTAssertTrue(state.isDirty)
        XCTAssertEqual(state.metadata?.title, "Next edit")
        XCTAssertNil(state.titles[next.url])
    }

    @MainActor
    func testSaveFailureKeepsEditsAndReportsError() async {
        let state = makeState { _, _ in
            throw NSError(domain: "SaveTest", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Write failed"])
        }
        await state.saveCurrent()
        XCTAssertTrue(state.isDirty)
        XCTAssertFalse(state.isSaving)
        XCTAssertEqual(state.lastError, "Write failed")
        XCTAssertTrue(state.titles.isEmpty)
    }

    @MainActor
    func testConcurrentSaveAndBatchWritesAreRejected() async {
        let started = expectation(description: "One background write")
        started.assertForOverFulfill = true
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let state = makeState { _, _ in
            started.fulfill()
            XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
        }
        let save = Task { await state.saveCurrent() }
        await fulfillment(of: [started], timeout: 3)
        await state.saveCurrent()
        XCTAssertNotNil(state.lastError)
        state.applyBatch(BatchPlan())
        XCTAssertFalse(state.batchInProgress)
        release.signal()
        await save.value
        XCTAssertFalse(state.isSaving)
    }
}
