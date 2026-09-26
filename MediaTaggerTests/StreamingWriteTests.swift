import XCTest
import Darwin
@testable import MediaTagger

final class StreamingWriteTests: XCTestCase {
    private var directory: URL!
    // Cross two streaming-copy boundaries without constructing a large Data.
    private let payloadSize = UInt64(IOStreaming.defaultChunkSize * 2 + 17)
    private var markers: [(UInt64, UInt8)] {
        [(0, 0xA1), (UInt64(IOStreaming.defaultChunkSize) - 1, 0xB2),
         (UInt64(IOStreaming.defaultChunkSize), 0xC3), (payloadSize - 1, 0xD4)]
    }

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".streaming-write-fixtures-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    func testAIFFStreamsSparseAudioAndPreservesChunkPadding() throws {
        let url = directory.appendingPathComponent("audio.aifc")
        let comm = chunk("COMM", Data([1, 2, 3]), bigEndian: true)
        let oldID3 = chunk("ID3 ", Data("obsolete".utf8), bigEndian: true)
        let ssndHeader = Data("SSND".utf8) + integer(payloadSize, bytes: 4)
        let trailing = chunk("MARK", Data([4, 5]), bigEndian: true)
        let prefix = Data("FORM".utf8) + integer(0, bytes: 4) + Data("AIFC".utf8)
            + comm + oldID3 + ssndHeader
        try sparseFile(url, prefix: prefix, suffix: Data([0xEE]) + trailing + oldID3)

        try AIFFFile.write(url: url, entries: [("TITLE", "Streamed AIFF")], cover: nil)

        let expectedPrefix = comm + ssndHeader
        XCTAssertEqual(try read(url, at: 8, count: 4), Data("AIFC".utf8))
        XCTAssertEqual(try read(url, at: 12, count: expectedPrefix.count), expectedPrefix)
        let payloadStart = UInt64(12 + expectedPrefix.count)
        try assertSparsePayload(url, at: payloadStart)
        XCTAssertEqual(try read(url, at: payloadStart + payloadSize,
                                count: 1 + trailing.count), Data([0xEE]) + trailing)
        let decoded = try AIFFFile.read(url).decoded()
        XCTAssertEqual(decoded.entries.filter { $0.key == "TITLE" }.map(\.value), ["Streamed AIFF"])
        XCTAssertEqual(decode(try read(url, at: 4, count: 4)), IOStreaming.fileSize(of: url) - 8)
    }

    func testAVIStreamsSparseMoviAndDropsOnlyInfoLists() throws {
        let url = directory.appendingPathComponent("video.avi")
        let oldInfo = chunk("LIST", Data("INFO".utf8) + chunk("INAM", Data("old".utf8),
                                                            bigEndian: false), bigEndian: false)
        let moviHeader = Data("LIST".utf8) + integer(payloadSize + 4, bytes: 4, bigEndian: false)
            + Data("movi".utf8)
        let trailing = chunk("LIST", Data("hdrl".utf8), bigEndian: false)
            + chunk("JUNK", Data([7, 8, 9]), bigEndian: false)
        let prefix = Data("RIFF".utf8) + integer(0, bytes: 4) + Data("AVI ".utf8)
            + oldInfo + moviHeader
        try sparseFile(url, prefix: prefix, suffix: Data([0xEE]) + trailing + oldInfo)

        try AVIFile.write(url: url, entries: [("TITLE", "Streamed AVI")])

        XCTAssertEqual(try read(url, at: 8, count: 4), Data("AVI ".utf8))
        XCTAssertEqual(try read(url, at: 12, count: moviHeader.count), moviHeader)
        let payloadStart = UInt64(12 + moviHeader.count)
        try assertSparsePayload(url, at: payloadStart)
        XCTAssertEqual(try read(url, at: payloadStart + payloadSize,
                                count: 1 + trailing.count), Data([0xEE]) + trailing)
        XCTAssertEqual(try AVIFile.read(url).entries.filter { $0.key == "TITLE" }.map(\.value),
                       ["Streamed AVI"])
        XCTAssertEqual(decode(try read(url, at: 4, count: 4), bigEndian: false),
                       IOStreaming.fileSize(of: url) - 8)
    }

    func testAVIWriterResidentMemoryDoesNotScaleWithSparseMediaSize() throws {
        let url = directory.appendingPathComponent("memory.avi")
        // Warm the writer and filesystem replacement code before measuring.
        let riffHeader = Data("RIFF".utf8) + integer(4, bytes: 4, bigEndian: false) + Data("AVI ".utf8)
        try riffHeader.write(to: url)
        try AVIFile.write(url: url, entries: [("TITLE", "warmup")])

        let mediaSize: UInt64 = 192 * 1024 * 1024
        let header = Data("RIFF".utf8) + integer(mediaSize + 16, bytes: 4, bigEndian: false)
            + Data("AVI LIST".utf8) + integer(mediaSize + 4, bytes: 4, bigEndian: false)
            + Data("movi".utf8)
        try header.write(to: url)
        let source = try FileHandle(forWritingTo: url)
        try source.seek(toOffset: UInt64(header.count) + mediaSize - 1)
        try source.write(contentsOf: Data([0xD4]))
        try source.close()

        let sampler = ResidentMemorySampler()
        let baseline = try ResidentMemorySampler.residentBytes()
        sampler.sample(baseline)
        let queue = DispatchQueue(label: "MediaTaggerTests.writer-memory")
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(1))
        timer.setEventHandler {
            if let bytes = try? ResidentMemorySampler.residentBytes() { sampler.sample(bytes) }
        }
        timer.resume()
        defer {
            timer.cancel()
            queue.sync {}
        }

        try AVIFile.write(url: url, entries: [("TITLE", "memory-bounded")])
        sampler.sample(try ResidentMemorySampler.residentBytes())
        timer.cancel()
        queue.sync {}
        let peakGrowth = sampler.peak > baseline ? sampler.peak - baseline : 0
        let measurement = XCTAttachment(string:
            "Sparse media: \(mediaSize) bytes; baseline RSS: \(baseline); peak RSS: \(sampler.peak); growth: \(peakGrowth)")
        measurement.name = "AVI streaming writer resident-memory measurement"
        measurement.lifetime = .keepAlways
        add(measurement)
        // Allows allocator/runtime overhead above the 16-MiB copy buffer,
        // but rejects materializing even one full 192-MiB media payload.
        XCTAssertLessThan(peakGrowth, 96 * 1024 * 1024,
                          "Writer resident memory grew with the media payload")
        XCTAssertEqual(try read(url, at: UInt64(header.count) + mediaSize - 1, count: 1), Data([0xD4]))
        XCTAssertEqual(try AVIFile.read(url).entries.first { $0.key == "TITLE" }?.value, "memory-bounded")
    }

    func testMP4StreamsExtendedMdatAndPatchesBothOffsetTables() throws {
        try checkMP4(moovFirst: true)
    }

    private final class ResidentMemorySampler: @unchecked Sendable {
        private let lock = NSLock()
        private var peakBytes: UInt64 = 0

        var peak: UInt64 {
            lock.lock()
            defer { lock.unlock() }
            return peakBytes
        }

        func sample(_ bytes: UInt64) {
            lock.lock()
            defer { lock.unlock() }
            peakBytes = max(peakBytes, bytes)
        }

        static func residentBytes() throws -> UInt64 {
            var info = mach_task_basic_info()
            var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
                }
            }
            guard result == KERN_SUCCESS else {
                throw NSError(domain: NSMachErrorDomain, code: Int(result))
            }
            return UInt64(info.resident_size)
        }
    }

    func testMP4KeepsOffsetsWhenMoovFollowsMdat() throws {
        try checkMP4(moovFirst: false)
    }

    private func checkMP4(moovFirst: Bool) throws {
        let url = directory.appendingPathComponent("video.mp4")
        let ftyp = atom("ftyp", Data("isom".utf8))
        let mdatHeader = integer(1, bytes: 4) + Data("mdat".utf8)
            + integer(payloadSize + 16, bytes: 8)
        let placeholder = moov(offset: 0)
        let originalPayloadStart = UInt64(ftyp.count + (moovFirst ? placeholder.count : 0) + 16)
        let oldMoov = moov(offset: originalPayloadStart)
        let trailer = atom("free", Data([5, 4, 3, 2, 1]))
        try sparseFile(url, prefix: ftyp + (moovFirst ? oldMoov : Data()) + mdatHeader,
                       suffix: (moovFirst ? Data() : oldMoov) + trailer)
        let oldHandle = try FileHandle(forReadingFrom: url)
        defer { try? oldHandle.close() }
        let originalSize = try oldHandle.seekToEnd()

        // A second, shorter title exercises negative as well as positive deltas.
        for title in [String(repeating: "long title ", count: 100), "short"] {
            try MP4File.write(url: url, entries: [("TITLE", title)], cover: nil)
            let atoms = try topAtoms(url)
            XCTAssertEqual(atoms.map(\.type), moovFirst
                           ? ["ftyp", "moov", "mdat", "free"] : ["ftyp", "mdat", "moov", "free"])
            let mdat = try XCTUnwrap(atoms.first { $0.type == "mdat" })
            let moovAtom = try XCTUnwrap(atoms.first { $0.type == "moov" })
            let newPayloadStart = mdat.offset + 16
            XCTAssertEqual(try read(url, at: mdat.offset, count: 16), mdatHeader)
            try assertSparsePayload(url, at: newPayloadStart)
            let moovBytes = try read(url, at: moovAtom.offset, count: Int(moovAtom.size))
            for (name, width) in [("stco", 4), ("co64", 8)] {
                let range = try XCTUnwrap(moovBytes.range(of: Data(name.utf8)))
                let offset = decode(moovBytes.subdata(in: range.upperBound + 8..<range.upperBound + 8 + width))
                XCTAssertEqual(offset, newPayloadStart)
            }
            if !moovFirst { XCTAssertEqual(newPayloadStart, originalPayloadStart) }
            XCTAssertEqual(try read(url, at: IOStreaming.fileSize(of: url) - UInt64(trailer.count),
                                    count: trailer.count), trailer)
            XCTAssertEqual(try MP4File.read(url).decoded().entries.first { $0.key == "TITLE" }?.value,
                           title)
            // Replacement leaves readers of the original inode untouched.
            XCTAssertEqual(try oldHandle.seekToEnd(), originalSize)
        }
    }

    func testMatroskaStreamsSparseClusterWithExistingReplacementPolicy() throws {
        let url = directory.appendingPathComponent("video.mkv")
        let ebml = Data([0x1A, 0x45, 0xDF, 0xA3, 0x84, 0x42, 0x86, 0x81, 0x01])
        let segmentID = Data([0x18, 0x53, 0x80, 0x67])
        let dropped = Data([0x11, 0x4D, 0x9B, 0x74, 0x83, 1, 2, 3,
                            0x12, 0x54, 0xC3, 0x67, 0x83, 4, 5, 6,
                            0x19, 0x41, 0xA4, 0x69, 0x83, 7, 8, 9])
        let tracks = Data([0x16, 0x54, 0xAE, 0x6B, 0x80])
        let clusterHeader = Data([0x1F, 0x43, 0xB6, 0x75]) + vint(payloadSize)
        let void = Data([0xEC, 0x83, 0x91, 0x92, 0x93])
        let segmentSize = UInt64(dropped.count + tracks.count + clusterHeader.count + void.count) + payloadSize
        try sparseFile(url, prefix: ebml + segmentID + vint(segmentSize) + dropped + tracks + clusterHeader,
                       suffix: void)

        let cover = Data([0x89, 0x50, 0x4E, 0x47, 0xDA, 0xDB])
        try MatroskaFile.write(url: url, entries: [("TITLE", "Streamed MKV")],
                              cover: (cover, "image/png"))

        let expectedPrefix = ebml + segmentID + Data([0xFF]) + tracks + clusterHeader
        XCTAssertEqual(try read(url, at: 0, count: expectedPrefix.count), expectedPrefix)
        let payloadStart = UInt64(expectedPrefix.count)
        try assertSparsePayload(url, at: payloadStart)
        let suffixStart = payloadStart + payloadSize
        let suffix = try read(url, at: suffixStart,
                              count: Int(IOStreaming.fileSize(of: url) - suffixStart))
        XCTAssertEqual(Data(suffix.prefix(void.count)), void)
        XCTAssertEqual(Data(suffix.dropFirst(void.count).prefix(4)), Data([0x12, 0x54, 0xC3, 0x67]))
        XCTAssertNotNil(suffix.range(of: Data("Streamed MKV".utf8)))
        XCTAssertNotNil(suffix.range(of: cover))
        XCTAssertNil(suffix.range(of: dropped))
    }

    private func sparseFile(_ url: URL, prefix: Data, suffix: Data) throws {
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: prefix))
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        for (offset, byte) in markers {
            try handle.seek(toOffset: UInt64(prefix.count) + offset)
            try handle.write(contentsOf: Data([byte]))
        }
        try handle.seek(toOffset: UInt64(prefix.count) + payloadSize)
        try handle.write(contentsOf: suffix)
    }

    private func assertSparsePayload(_ url: URL, at offset: UInt64) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        var position: UInt64 = 0
        while position < payloadSize {
            let count = Int(min(64 * 1024, payloadSize - position))
            var expected = Data(repeating: 0, count: count)
            for (marker, byte) in markers where marker >= position && marker < position + UInt64(count) {
                expected[Int(marker - position)] = byte
            }
            let actual = try handle.read(upToCount: count)
            guard actual == expected else {
                XCTFail("Media payload differs at relative offset \(position)")
                return
            }
            position += UInt64(count)
        }
    }

    private func read(_ url: URL, at offset: UInt64, count: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        return try handle.read(upToCount: count) ?? Data()
    }

    private func integer(_ value: UInt64, bytes: Int, bigEndian: Bool = true) -> Data {
        let shifts = bigEndian ? Array((0..<bytes).reversed()) : Array(0..<bytes)
        return Data(shifts.map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }

    private func decode(_ bytes: Data, bigEndian: Bool = true) -> UInt64 {
        (bigEndian ? Array(bytes) : Array(bytes.reversed())).reduce(0) { ($0 << 8) | UInt64($1) }
    }

    private func chunk(_ id: String, _ payload: Data, bigEndian: Bool) -> Data {
        Data(id.utf8) + integer(UInt64(payload.count), bytes: 4, bigEndian: bigEndian)
            + payload + (payload.count & 1 == 1 ? Data([0xEE]) : Data())
    }

    private func atom(_ type: String, _ payload: Data) -> Data {
        integer(UInt64(payload.count + 8), bytes: 4) + Data(type.utf8) + payload
    }

    private func moov(offset: UInt64) -> Data {
        let tableHeader = integer(0, bytes: 4) + integer(1, bytes: 4)
        let tables = atom("stco", tableHeader + integer(offset, bytes: 4))
            + atom("co64", tableHeader + integer(offset, bytes: 8))
        return atom("moov", atom("trak", atom("mdia", atom("minf", atom("stbl", tables)))))
    }

    private func vint(_ value: UInt64) -> Data {
        integer(value | (UInt64(1) << 56), bytes: 8)
    }

    private func topAtoms(_ url: URL) throws -> [(type: String, offset: UInt64, size: UInt64)] {
        var atoms: [(String, UInt64, UInt64)] = []
        var position: UInt64 = 0
        let size = IOStreaming.fileSize(of: url)
        while position + 8 <= size {
            let header = try read(url, at: position, count: 8)
            var atomSize = decode(Data(header.prefix(4)))
            if atomSize == 1 { atomSize = decode(try read(url, at: position + 8, count: 8)) }
            guard atomSize >= 8, atomSize <= size - position else {
                XCTFail("Invalid output atom size")
                break
            }
            atoms.append((String(decoding: header.suffix(4), as: UTF8.self), position, atomSize))
            position += atomSize
        }
        return atoms
    }
}
