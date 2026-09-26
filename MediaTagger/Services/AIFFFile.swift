import Foundation

/// Native AIFF / AIFF-C reader & writer for embedded ID3v2 metadata.
///
/// AIFF is an IFF-style container:
///   "FORM" + size (4 BE) + "AIFF" (or "AIFC") + chunks
/// Each chunk is `4-byte ID + 4-byte BE size + payload`, padded with one NUL
/// byte if the payload size is odd (the pad byte is NOT counted in the size).
///
/// iTunes-style AIFF files store metadata in an "ID3 " chunk whose payload is
/// a complete ID3v2 tag identical to what we write for MP3. We simply replace
/// (or insert) that chunk and rewrite the file; all other chunks (COMM/SSND/
/// MARK/etc.) are preserved verbatim.
enum AIFFError: Error, LocalizedError {
    case notAIFF
    case truncated
    var errorDescription: String? {
        switch self {
        case .notAIFF:    return "File is not a valid AIFF/AIFC container"
        case .truncated:  return "AIFF file is truncated"
        }
    }
}

struct AIFFFile {

    let url: URL
    /// Embedded ID3v2 tag (if any); summary reads retain title/track frames only.
    let id3Chunk: Data?

    // MARK: - Read

    /// Stream the chunk list via `FileHandle`: read the 12-byte FORM header,
    /// then for each chunk read its 8-byte header and seek past unwanted
    /// payloads. Only the "ID3 " chunk's payload is actually loaded —
    /// avoiding the multi-GB read that `Data(contentsOf:, .mappedIfSafe)`
    /// triggers on non-local volumes.
    static func read(_ url: URL, summaryOnly: Bool = false) throws -> AIFFFile {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        let fileSize = (try? h.seekToEnd()) ?? 0
        try h.seek(toOffset: 0)

        let head = h.readData(ofLength: 12)
        guard head.count == 12 else { throw AIFFError.truncated }
        guard head[0] == 0x46, head[1] == 0x4F,
              head[2] == 0x52, head[3] == 0x4D
        else { throw AIFFError.notAIFF }                           // "FORM"
        let formType = String(data: head.subdata(in: 8..<12), encoding: .ascii) ?? ""
        guard formType == "AIFF" || formType == "AIFC" else { throw AIFFError.notAIFF }

        var p: UInt64 = 12
        var id3: Data?
        while p + 8 <= fileSize {
            if summaryOnly { try Task.checkCancellation() }
            try h.seek(toOffset: p)
            let chunkHeader = h.readData(ofLength: 8)
            guard chunkHeader.count == 8 else { break }
            let id = String(data: chunkHeader.prefix(4), encoding: .ascii) ?? ""
            let size = Int(beU32(chunkHeader, 4))
            let payloadStart = p + 8
            let payloadEnd = payloadStart + UInt64(size)
            guard payloadEnd <= fileSize else { break }
            if id == "ID3 " {
                if summaryOnly {
                    id3 = try? ID3v2File.readSummaryTag(
                        handle: h, offset: payloadStart, available: UInt64(size))
                    try Task.checkCancellation()
                } else {
                    id3 = h.readData(ofLength: size)
                    if id3?.count != size { id3 = nil; break }
                }
            }
            // Advance past payload + 1-byte pad if odd.
            p = payloadEnd + UInt64(size & 1)
        }
        return AIFFFile(url: url, id3Chunk: id3)
    }

    /// Decode the embedded ID3v2 tag (if any) into Vorbis-style entries.
    func decoded() -> (entries: [(key: String, value: String)],
                       cover: (data: Data, mime: String)?) {
        guard let id3 = id3Chunk,
              let parsed = try? ID3v2File.parse(id3, url: url)
        else { return ([], nil) }
        return parsed.decoded()
    }

    // MARK: - Write

    /// Replace (or insert) the "ID3 " chunk inside `url` and rewrite the file
    /// atomically. Other chunks are preserved verbatim, in original order.
    static func write(url: URL,
                      entries: [(key: String, value: String)],
                      cover: (data: Data, mime: String)?) throws {
        let source = try FileHandle(forReadingFrom: url)
        defer { try? source.close() }
        let fileSize = try source.seekToEnd()
        try source.seek(toOffset: 0)
        let header = try source.read(upToCount: 12) ?? Data()
        guard header.count == 12,
              header[0] == 0x46, header[1] == 0x4F,
              header[2] == 0x52, header[3] == 0x4D
        else { throw AIFFError.notAIFF }

        // Build the new ID3v2 tag payload by reusing the MP3 path.
        let newID3 = encodedID3(entries: entries, cover: cover)

        try IOStreaming.writeAtomically(to: url) { tmp in
            let destination = try FileHandle(forWritingTo: tmp)
            defer { try? destination.close() }
            try destination.write(contentsOf: header)

            // Preserve each non-ID3 chunk, including its original pad byte.
            var p: UInt64 = 12
            while p + 8 <= fileSize {
                try source.seek(toOffset: p)
                let chunkHeader = try source.read(upToCount: 8) ?? Data()
                guard chunkHeader.count == 8 else { throw AIFFError.truncated }
                let id = String(data: chunkHeader.prefix(4), encoding: .ascii) ?? ""
                let size = UInt64(beU32(chunkHeader, 4))
                let payloadEnd = p + 8 + size
                guard payloadEnd <= fileSize else { break }
                let chunkEnd = min(payloadEnd + (size & 1), fileSize)
                if id != "ID3 " {
                    try source.seek(toOffset: p)
                    try IOStreaming.stream(from: source, into: destination,
                                           byteCount: chunkEnd - p)
                }
                p = chunkEnd
            }

            try destination.write(contentsOf: Data("ID3 ".utf8))
            try destination.write(contentsOf: beU32Bytes(UInt32(newID3.count)))
            try destination.write(contentsOf: newID3)
            if newID3.count & 1 == 1 { try destination.write(contentsOf: Data([0])) }
            let outputSize = try destination.offset()
            guard let formSize = UInt32(exactly: outputSize - 8) else {
                throw NSError(domain: "MediaTagger.AIFF", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "AIFF exceeds the FORM size limit"])
            }
            try destination.seek(toOffset: 4)
            try destination.write(contentsOf: beU32Bytes(formSize))
        }
    }

    private static func encodedID3(entries: [(key: String, value: String)],
                                   cover: (data: Data, mime: String)?) -> Data {
        // Mirror ID3v2File.write's frame-building logic, but emit the encoded
        // tag bytes directly (no file I/O).
        var newFrames: [ID3Frame] = []
        var trackNum: String?, trackTot: String?
        var discNum: String?, discTot: String?

        for (rawKey, value) in entries {
            let key = rawKey.uppercased()
            guard !value.isEmpty else { continue }
            switch key {
            case "TRACKNUMBER": trackNum = value
            case "TRACKTOTAL":  trackTot = value
            case "DISCNUMBER":  discNum  = value
            case "DISCTOTAL":   discTot  = value
            case "COMMENT":
                newFrames.append(ID3Frame(id: "COMM", data: ID3Frame.encodeCOMM(value)))
            case "DATE":
                newFrames.append(ID3Frame(id: "TYER", data: ID3Frame.encodeText(value)))
                newFrames.append(ID3Frame(id: "TDRC", data: ID3Frame.encodeText(value)))
            default:
                if let frameId = ID3v2File.frameByKey[key] {
                    newFrames.append(ID3Frame(id: frameId, data: ID3Frame.encodeText(value)))
                } else {
                    newFrames.append(ID3Frame(id: "TXXX", data: ID3Frame.encodeTXXX(description: key, value: value)))
                }
            }
        }
        if let trackNum {
            let s = trackTot.map { "\(trackNum)/\($0)" } ?? trackNum
            newFrames.append(ID3Frame(id: "TRCK", data: ID3Frame.encodeText(s)))
        }
        if let discNum {
            let s = discTot.map { "\(discNum)/\($0)" } ?? discNum
            newFrames.append(ID3Frame(id: "TPOS", data: ID3Frame.encodeText(s)))
        }
        if let cover {
            newFrames.append(ID3Frame(id: "APIC", data: ID3Frame.encodeAPIC(data: cover.data, mime: cover.mime)))
        }
        return ID3v2File.encodeTag(frames: newFrames, padding: 1024)
    }

}

// MARK: - helpers (file-private to avoid clashing with other parsers)

fileprivate func beU32(_ d: Data, _ p: Int) -> UInt32 {
    (UInt32(d[p]) << 24) | (UInt32(d[p+1]) << 16) |
    (UInt32(d[p+2]) << 8) |  UInt32(d[p+3])
}
fileprivate func beU32Bytes(_ v: UInt32) -> Data {
    Data([UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF),
          UInt8(v >> 8  & 0xFF), UInt8(v       & 0xFF)])
}
