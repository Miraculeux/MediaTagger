import Foundation

/// Helpers for streaming large files in/out of disk in fixed-size chunks,
/// avoiding the multi-GB memory spikes that happen when a metadata writer
/// loads an entire audio file into `Data` just to patch a few bytes of tags.
enum IOStreaming {
    /// 16 MiB chunks: fewer syscalls on slow external/network volumes where
    /// each `read()`/`write()` has measurable latency. Still small enough
    /// that the resident-set bump while streaming a 1 GB FLAC stays bounded.
    static let defaultChunkSize = 16 * 1024 * 1024

    enum Error: Swift.Error, LocalizedError {
        case shortRead(expected: UInt64, actual: UInt64)
        var errorDescription: String? {
            switch self {
            case let .shortRead(expected, actual):
                return "Streaming copy ended early: expected \(expected) bytes, got \(actual)"
            }
        }
    }

    /// Copy exactly `byteCount` bytes from `source`'s current read pointer
    /// into `dest`'s current write pointer, in chunks.
    static func stream(from source: FileHandle,
                       into dest: FileHandle,
                       byteCount: UInt64,
                       chunkSize: Int = defaultChunkSize) throws {
        var remaining = byteCount
        while remaining > 0 {
            let toRead = Int(min(UInt64(chunkSize), remaining))
            let buf = try source.read(upToCount: toRead) ?? Data()
            if buf.isEmpty { throw Error.shortRead(expected: byteCount, actual: byteCount - remaining) }
            try dest.write(contentsOf: buf)
            remaining -= UInt64(buf.count)
        }
    }

    /// Create a sibling temp file, hand it to `build`, then atomically swap
    /// it in for `url`. Cleans up the temp file on failure.
    static func writeAtomically(to url: URL, build: (URL) throws -> Void) throws {
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        do {
            FileManager.default.createFile(atPath: tmp.path, contents: nil)
            try build(tmp)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
    }

    /// Fetch a file's size via stat; returns 0 if unavailable.
    static func fileSize(of url: URL) -> UInt64 {
        let n = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? nil
        return n ?? 0
    }
}
