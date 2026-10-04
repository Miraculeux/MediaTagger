import XCTest
import AppKit
import UniformTypeIdentifiers
@testable import MediaTagger

final class DroppedImageImporterTests: XCTestCase {
    private func png() throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 8, bitsPerPixel: 32
        ))
        bitmap.bitmapData?.initialize(repeating: 255, count: 16)
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: folder) }
        return folder
    }

    @MainActor
    func testPasteboardPrefersImageBytesOverWebLinkAndSnapshotsMultipleItems() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let image = NSPasteboardItem()
        let bytes = try png()
        image.setData(bytes, forType: .png)
        image.setString("https://example.com/photo.jpg", forType: DroppedImageImporter.urlPasteboardType)
        let remote = NSPasteboardItem()
        remote.setString("https://example.com/image?id=42", forType: DroppedImageImporter.urlPasteboardType)
        let duplicate = NSPasteboardItem()
        duplicate.setString("https://example.com/image?id=42", forType: DroppedImageImporter.urlPasteboardType)
        let invalid = NSPasteboardItem()
        invalid.setString("javascript:alert(1)", forType: DroppedImageImporter.urlPasteboardType)
        pasteboard.writeObjects([image, remote, duplicate, invalid])
        let sources = DroppedImageImporter.sources(from: pasteboard)
        XCTAssertEqual(sources.count, 2)
        guard case .data(let data, let filename) = sources[0],
              case .url(let url) = sources[1] else { return XCTFail("Unexpected drag sources") }
        XCTAssertEqual(data, bytes)
        XCTAssertEqual(filename, "photo.jpg")
        XCTAssertEqual(url.absoluteString, "https://example.com/image?id=42")
        pasteboard.clearContents()
        XCTAssertEqual(data, bytes)
    }

    func testImageContentDeterminesExtensionAndCollisionsNeverOverwrite() async throws {
        let folder = try temporaryFolder()
        let bytes = try png()
        let source = DroppedImageSource.data(bytes, filename: "cover.jpg")
        let first = try await DroppedImageImporter.importImage(source, into: folder)
        let second = try await DroppedImageImporter.importImage(source, into: folder)
        XCTAssertEqual(first.lastPathComponent, "cover.png")
        XCTAssertEqual(second.lastPathComponent, "cover (2).png")
        XCTAssertEqual(try Data(contentsOf: first), bytes)
        XCTAssertEqual(try Data(contentsOf: second), bytes)
    }

    func testLocalImageIsCopiedAndTIFFPayloadIsSupported() async throws {
        let folder = try temporaryFolder()
        let original = folder.appendingPathComponent("original.png")
        try png().write(to: original)
        let copy = try await DroppedImageImporter.importImage(.url(original), into: folder)
        XCTAssertEqual(copy.lastPathComponent, "original (2).png")
        XCTAssertEqual(try Data(contentsOf: original), try Data(contentsOf: copy))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: png()))
        let tiff = try XCTUnwrap(bitmap.tiffRepresentation)
        let imported = try await DroppedImageImporter.importImage(.data(tiff, filename: "image"), into: folder)
        XCTAssertTrue(MediaFile.isImage(imported))
        XCTAssertEqual(try Data(contentsOf: imported), tiff)
    }

    func testExtensionlessRemoteImageUsesDecodedContent() async throws {
        let folder = try temporaryFolder()
        let bytes = try png()
        let session = mockSession()
        defer { session.invalidateAndCancel() }
        let url = URL(string: "https://example.com/image?id=42")!
        let result = try await DroppedImageImporter.importImage(.url(url), into: folder, session: session)
        XCTAssertEqual(result.lastPathComponent, "image.png")
        XCTAssertEqual(try Data(contentsOf: result), bytes)
    }

    func testUnsupportedImageFormatIsConvertedToListedPNG() async throws {
        let folder = try temporaryFolder()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: png()))
        let bmp = try XCTUnwrap(bitmap.representation(using: .bmp, properties: [:]))
        let result = try await DroppedImageImporter.importImage(
            .data(bmp, filename: "photo.bmp"), into: folder
        )
        XCTAssertEqual(result.lastPathComponent, "photo.png")
        XCTAssertTrue(MediaFile.isImage(result))
        let decoded = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: result)))
        XCTAssertEqual(decoded.pixelsWide, bitmap.pixelsWide)
        XCTAssertEqual(decoded.pixelsHigh, bitmap.pixelsHigh)
    }

    @MainActor
    func testWriteFailureIsReportedWithoutAddingFile() async throws {
        let folder = try temporaryFolder().appendingPathComponent("missing")
        let state = AppState(metadataWriter: { _, _ in })
        state.selectedFolder = folder
        await state.importDroppedImages([.data(try png(), filename: "cover.png")], into: folder)
        XCTAssertNotNil(state.imageImportError)
        XCTAssertFalse(state.isImportingImages)
        XCTAssertTrue(state.files.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    func testHTTPFailureAndWebpageDoNotCreateFiles() async throws {
        let folder = try temporaryFolder()
        let session = mockSession()
        defer { session.invalidateAndCancel() }
        for path in ["missing", "webpage"] {
            do {
                _ = try await DroppedImageImporter.importImage(
                    .url(URL(string: "https://example.com/\(path)")!), into: folder, session: session
                )
                XCTFail("Non-image response must fail")
            } catch let error as DroppedImageImporter.ImportError {
                switch (path, error) {
                case ("missing", .downloadFailed(404)), ("webpage", .invalidImage): break
                default: XCTFail("Unexpected error: \(error)")
                }
            }
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }

    @MainActor
    func testImportUpdatesListWithoutDiscardingEditsAndReportsPartialFailures() async throws {
        let folder = try temporaryFolder()
        let state = AppState(metadataWriter: { _, _ in })
        state.selectedFolder = folder
        let selected = MediaFile(id: folder.appendingPathComponent("track.flac"))
        state.files = [selected]
        state.selectedFile = selected
        state.selectedFileIDs = [selected.id]
        state.metadata = MediaMetadata(tags: [.init(key: "TITLE", value: "Unsaved")])
        state.isDirty = true
        await state.importDroppedImages([
            .data(Data("not an image".utf8), filename: "bad.png"),
            .data(try png(), filename: "cover.png")
        ], into: folder)
        XCTAssertEqual(state.files.map(\.name), ["track.flac", "cover.png"])
        XCTAssertEqual(state.selectedFileIDs, [selected.id])
        XCTAssertEqual(state.selectedFile, selected)
        XCTAssertEqual(state.metadata?.title, "Unsaved")
        XCTAssertTrue(state.isDirty)
        XCTAssertNotNil(state.imageImportError)
        XCTAssertFalse(state.isImportingImages)
    }

    @MainActor
    func testImportDoesNotAddFilesToAnotherFolder() async throws {
        let folder = try temporaryFolder()
        let state = AppState(metadataWriter: { _, _ in })
        state.selectedFolder = folder.appendingPathComponent("another-folder")
        await state.importDroppedImages([.data(try png(), filename: "cover.png")], into: folder)
        XCTAssertTrue(state.files.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("cover.png").path))
        XCTAssertNil(state.imageImportError)
    }

    private func mockSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ImageURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private final class ImageURLProtocol: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            do {
                let url = try XCTUnwrap(request.url)
                let isImage = url.path == "/image"
                let response = try XCTUnwrap(HTTPURLResponse(
                    url: url, statusCode: url.path == "/missing" ? 404 : 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": isImage ? "image/png" : "text/html"]
                ))
                let data = isImage ? try DroppedImageImporterTests().png() : Data("<html>Not an image</html>".utf8)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }
        override func stopLoading() {}
    }
}
