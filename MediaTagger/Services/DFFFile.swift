import Foundation

/// Native DFF (DSDIFF / DSD Interchange File Format) tag reader & writer.
///
/// DSDIFF is an IFF-style container with **64-bit chunk sizes** (FORM8):
///   "FRM8" + size (8 BE) + "DSD " (form type) + chunks
/// Each chunk is `4-byte ID + 8-byte BE size + payload`, padded with one NUL
/// byte if the payload size is odd (the pad byte is NOT counted in the size).
///
/// DSDIFF has its own native metadata chunks (DIIN with DITI/DIAR/DIDT…), but
/// the de-facto industry convention used by foobar2000, JRiver, dBpoweramp and
/// others is to embed a complete ID3v2 tag in an `"ID3 "` chunk inside FRM8.
/// We follow that convention: read/write the standard ID3v2 tag we already use
/// for MP3/AIFF/DSF, leaving the audio (`DSD ` chunk) and any other metadata
/// chunks untouched.
enum DFFError: Error, LocalizedError {
    case notDFF
    case truncated
    var errorDescription: String? {
        switch self {
        case .notDFF:    return "File is not a valid DSDIFF (DFF) container"
        case .truncated: return "DFF file is truncated"
        }
    }
}

struct DFFFile {

    let url: URL
    /// Raw payload of the embedded "ID3 " chunk (a complete ID3v2 tag), if any.
    let id3Chunk: Data?
    /// Stream-level audio properties read from FRM8/PROP/SND sub-chunks.
    let techInfo: MediaTechnicalInfo

    // MARK: - Read

    /// Stream FRM8 children via `FileHandle`. DSDIFF audio (`DSD ` chunk) is
    /// the bulk of the file (multi-GB on DSD256 albums); we only need to
    /// read its 12-byte chunk header to learn its size, never its payload.
    /// `Data(contentsOf: .mappedIfSafe)` quietly falls back to a full file
    /// copy on non-local volumes, which made sidebar prefetch O(file_bytes).
    static func read(_ url: URL) throws -> DFFFile {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        let fileSize = (try? h.seekToEnd()) ?? 0
        try h.seek(toOffset: 0)

        let head = h.readData(ofLength: 16)
        guard head.count == 16,
              head[0] == 0x46, head[1] == 0x52,
              head[2] == 0x4D, head[3] == 0x38
        else { throw DFFError.notDFF }                              // "FRM8"
        let formType = String(data: head.subdata(in: 12..<16), encoding: .ascii) ?? ""
        guard formType == "DSD " else { throw DFFError.notDFF }

        var p: UInt64 = 16
        var id3: Data?
        var tech = MediaTechnicalInfo()
        tech.container = "DFF"
        tech.codec = "DSD"
        tech.isDSD = true
        var dsdDataSize: UInt64 = 0

        while p + 12 <= fileSize {
            try h.seek(toOffset: p)
            let chunkHeader = h.readData(ofLength: 12)
            guard chunkHeader.count == 12 else { break }
            let id = String(data: chunkHeader.prefix(4), encoding: .ascii) ?? ""
            let size = UInt64(beU64(chunkHeader, 4))
            let payloadStart = p + 12
            let payloadEnd = min(payloadStart + size, fileSize)
            let payloadLen = Int(payloadEnd - payloadStart)
            switch id {
            case "ID3 ":
                id3 = h.readData(ofLength: payloadLen)
                if id3?.count != payloadLen { id3 = nil }
            case "PROP" where payloadLen >= 4:
                // PROP/SND is typically <200 bytes — read the whole payload.
                let body = h.readData(ofLength: payloadLen)
                if body.count >= 4,
                   String(data: body.prefix(4), encoding: .ascii) == "SND " {
                    parseSND(body, start: 4, end: body.count, into: &tech)
                }
            case "DSD ":
                // Skip the audio payload entirely — only the size matters.
                dsdDataSize = size
            default:
                break  // skipped via seek on next iteration
            }
            p = payloadEnd + UInt64(size & 1)        // 1-byte pad if odd
        }

        if let sr = tech.sampleRate, let ch = tech.channels, sr > 0, ch > 0 {
            tech.bitsPerSample = 1
            tech.bitrate = sr * Double(ch)
            if dsdDataSize > 0 {
                tech.durationSeconds = Double(dsdDataSize) * 8.0 / (sr * Double(ch))
            }
        }

        return DFFFile(url: url, id3Chunk: id3, techInfo: tech)
    }

    /// Parse FS / CHNL sub-chunks of the PROP/SND property list.
    private static func parseSND(_ data: Data, start: Int, end: Int,
                                 into tech: inout MediaTechnicalInfo) {
        var q = start
        while q + 12 <= end {
            let id = String(data: data.subdata(in: q..<q+4), encoding: .ascii) ?? ""
            let size = Int(beU64(data, q + 4))
            let pStart = q + 12
            let pEnd = min(pStart + size, end)
            switch id {
            case "FS  ":
                if pEnd - pStart >= 4 {
                    let fs = (UInt32(data[pStart]) << 24) | (UInt32(data[pStart+1]) << 16)
                           | (UInt32(data[pStart+2]) << 8)  |  UInt32(data[pStart+3])
                    tech.sampleRate = Double(fs)
                }
            case "CHNL":
                if pEnd - pStart >= 2 {
                    let ch = (UInt16(data[pStart]) << 8) | UInt16(data[pStart+1])
                    tech.channels = Int(ch)
                }
            default: break
            }
            q = pEnd + (size & 1)
        }
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
    /// atomically. All other top-level chunks (DSD audio, FVER, PROP, DIIN…)
    /// are preserved verbatim, in their original order.
    ///
    /// Streams non-ID3 chunks through a `FileHandle` instead of buffering
    /// them in memory. A multi-GB DSD file edited for tags only does one
    /// sequential pass plus a small ID3 write.
    ///
    /// Fast path: if the file has no ID3 chunk (or has exactly one and it
    /// is the **last** child of FRM8 — by far the common case, since every
    /// mainstream tagger appends ID3 there), we truncate at the old ID3's
    /// start and append the new one in place, then patch the 8-byte FRM8
    /// size field. This avoids rewriting the multi-GB `DSD ` audio chunk.
    /// Net IO drops from ~filesize down to ~tag size.
    static func write(url: URL,
                      entries: [(key: String, value: String)],
                      cover: (data: Data, mime: String)?) throws {
        // Pass 1: read header + walk chunk headers to build the keep-list
        // and detect whether an in-place truncate+append is safe.
        let src = try FileHandle(forReadingFrom: url)
        defer { try? src.close() }

        let head = try src.read(upToCount: 16) ?? Data()
        guard head.count >= 16,
              head[0] == 0x46, head[1] == 0x52,
              head[2] == 0x4D, head[3] == 0x38
        else { throw DFFError.notDFF }
        let formType = head.subdata(in: 12..<16)

        let totalFileSize = IOStreaming.fileSize(of: url)

        struct ChunkRange { let offset: UInt64; let length: UInt64 }
        var keepRanges: [ChunkRange] = []
        var keepBytes: UInt64 = 0
        var id3ChunkCount = 0
        var lastID3Start: UInt64? = nil
        var lastChunkWasID3 = false
        var p: UInt64 = 16

        while p + 12 <= totalFileSize {
            try src.seek(toOffset: p)
            let header = try src.read(upToCount: 12) ?? Data()
            if header.count < 12 { break }
            let id = String(data: header.prefix(4), encoding: .ascii) ?? ""
            let size = beU64(header, 4)
            let payloadEnd = p + 12 + size
            guard payloadEnd <= totalFileSize else { break }
            let chunkEnd = payloadEnd + (size & 1)
            let actualEnd = min(chunkEnd, totalFileSize)
            if id == "ID3 " {
                id3ChunkCount += 1
                lastID3Start = p
                lastChunkWasID3 = true
            } else {
                let length = actualEnd - p
                keepRanges.append(ChunkRange(offset: p, length: length))
                keepBytes += length
                lastChunkWasID3 = false
            }
            p = chunkEnd
        }

        let newID3 = encodedID3(entries: entries, cover: cover)
        let id3PaddingByte: UInt64 = (UInt64(newID3.count) & 1) == 1 ? 1 : 0
        let newID3Total: UInt64 = 12 + UInt64(newID3.count) + id3PaddingByte

        // In-place fast path: append-or-replace-tail.
        let canInPlace = (id3ChunkCount == 0) || (id3ChunkCount == 1 && lastChunkWasID3)
        if canInPlace {
            // bodyEnd = byte offset where the new ID3 chunk should start.
            // - No existing ID3:   append at current EOF.
            // - Trailing ID3:      truncate it off and append at its start.
            let bodyEnd: UInt64 = lastID3Start ?? totalFileSize
            let newFileSize: UInt64 = bodyEnd + newID3Total
            let newFormPayloadSize: UInt64 = newFileSize - 12

            let h = try FileHandle(forUpdating: url)
            defer { try? h.close() }

            if totalFileSize != bodyEnd {
                try h.truncate(atOffset: bodyEnd)
            }
            try h.seek(toOffset: bodyEnd)
            try h.write(contentsOf: Data("ID3 ".utf8))
            try h.write(contentsOf: beU64Bytes(UInt64(newID3.count)))
            try h.write(contentsOf: newID3)
            if id3PaddingByte == 1 { try h.write(contentsOf: Data([0])) }

            // Patch FRM8 size (8 BE at offset 4).
            try h.seek(toOffset: 4)
            try h.write(contentsOf: beU64Bytes(newFormPayloadSize))
            return
        }

        // Slow path: ID3 chunk lives somewhere in the middle, or the file
        // has multiple stale ID3 chunks. Stream a full rewrite to clean up.
        let formPayloadSize: UInt64 = 4 + keepBytes + newID3Total
        try IOStreaming.writeAtomically(to: url) { tmpURL in
            let dest = try FileHandle(forWritingTo: tmpURL)
            defer { try? dest.close() }

            try dest.write(contentsOf: Data("FRM8".utf8))
            try dest.write(contentsOf: beU64Bytes(formPayloadSize))
            try dest.write(contentsOf: formType)

            for range in keepRanges {
                try src.seek(toOffset: range.offset)
                try IOStreaming.stream(from: src, into: dest, byteCount: range.length)
            }

            try dest.write(contentsOf: Data("ID3 ".utf8))
            try dest.write(contentsOf: beU64Bytes(UInt64(newID3.count)))
            try dest.write(contentsOf: newID3)
            if id3PaddingByte == 1 { try dest.write(contentsOf: Data([0])) }
        }
    }

    private static func encodedID3(entries: [(key: String, value: String)],
                                   cover: (data: Data, mime: String)?) -> Data {
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
                    newFrames.append(ID3Frame(id: "TXXX",
                        data: ID3Frame.encodeTXXX(description: key, value: value)))
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
            newFrames.append(ID3Frame(id: "APIC",
                data: ID3Frame.encodeAPIC(data: cover.data, mime: cover.mime)))
        }
        return ID3v2File.encodeTag(frames: newFrames, padding: 1024)
    }
}

// MARK: - BE 64-bit helpers (file-private)

fileprivate func beU64(_ d: Data, _ p: Int) -> UInt64 {
    var v: UInt64 = 0
    for i in 0..<8 { v = (v << 8) | UInt64(d[p + i]) }
    return v
}

fileprivate func beU64Bytes(_ v: UInt64) -> Data {
    var out = [UInt8](repeating: 0, count: 8)
    for i in 0..<8 { out[i] = UInt8((v >> (56 - i * 8)) & 0xFF) }
    return Data(out)
}
