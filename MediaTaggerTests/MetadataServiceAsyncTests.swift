import AVFoundation
import XCTest
@testable import MediaTagger

final class MetadataServiceAsyncTests: XCTestCase {
    func testConcurrentFallbackReadsCompleteWithoutBlockingWorkers() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MetadataAsync-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try makeWave(at: url)
        let finished = expectation(description: "Concurrent AVFoundation reads")
        let reads = Task {
            defer { finished.fulfill() }
            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<24 {
                    group.addTask {
                        let service = MetadataService()
                        let full = try await service.read(url)
                        let summary = try await service.readSummary(url)
                        XCTAssertEqual(summary.title, full.title)
                        XCTAssertEqual(summary.trackDisplay, full.trackDisplay)
                    }
                }
                try await group.waitForAll()
            }
        }
        await fulfillment(of: [finished], timeout: 15)
        reads.cancel()
        try await reads.value
    }

    func testCancelledReadDoesNotStartFileIO() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await MetadataService().read(
                URL(fileURLWithPath: "/nonexistent/cancelled.wav"))
        }
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected cancellation, got \(error)")
        }
    }

    func testReadAllRetainsFallbackTechnicalInfo() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MetadataTech-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try makeWave(at: url)
        let (_, tech) = try await MetadataService().readAll(url)
        XCTAssertEqual(tech.sampleRate, 8_000)
        XCTAssertEqual(tech.channels, 1)
        XCTAssertEqual(try XCTUnwrap(tech.durationSeconds), 0.1, accuracy: 0.001)
    }

    private func makeWave(at url: URL) throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 800))
        buffer.frameLength = 800
        if let samples = buffer.floatChannelData {
            samples[0].update(repeating: 0, count: 800)
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
}
