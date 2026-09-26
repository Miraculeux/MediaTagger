import Foundation

/// Native AVI (RIFF) tag reader & writer.
///
/// AVI is a RIFF container:
///   "RIFF" + size (4 LE) + "AVI " + chunks
/// Standard metadata lives in a `LIST` chunk of type `INFO`, containing
/// 4-character chunks like `INAM` (title), `IART` (artist), `IPRD` (album),
/// `ICRD` (date), `IGNR` (genre), `ICMT` (comment), `IPRT` (track #),
/// `ITRK` (track #), `IMUS` (composer). Each chunk's payload is a
/// NUL-terminated ASCII/UTF-8 string, padded to even length.
///
/// Writing strategy: parse top-level RIFF children; drop any existing
/// `LIST/INFO` chunk; append a fresh `LIST/INFO` containing the new tags.
/// Cover art isn't part of the standard RIFF INFO set, so it's not written.
enum AVIError: Error, LocalizedError {
    case notAVI
    case truncated
    var errorDescription: String? {
        switch self {
        case .notAVI:     return "File is not a valid AVI/RIFF container"
        case .truncated:  return "AVI file is truncated"
        }
    }
}

struct AVIFile {

    let url: URL
    let entries: [(key: String, value: String)]

    // MARK: - Read

    /// Read RIFF INFO tags from an AVI file.
    ///
    /// Streams top-level RIFF children via `FileHandle` rather than
    /// `Data(contentsOf:)` so we don't pay a multi-GB mmap (or full copy on
    /// network volumes) just to find a few hundred bytes of INFO chunk.
    /// Total bytes read for a typical AVI: a few hundred KB at most.
    /// Summary reads seek past INFO values unrelated to title/track.
    static func read(_ url: URL, summaryOnly: Bool = false) throws -> AVIFile {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let fileSize = (try? handle.seekToEnd()) ?? 0
        try handle.seek(toOffset: 0)

        // RIFF + size + AVI — 12-byte header.
        let header = handle.readData(ofLength: 12)
        guard header.count >= 12,
              header[0] == 0x52, header[1] == 0x49,
              header[2] == 0x46, header[3] == 0x46
        else { throw AVIError.notAVI }                              // "RIFF"
        let formType = String(data: header.subdata(in: 8..<12), encoding: .ascii) ?? ""
        guard formType == "AVI " else { throw AVIError.notAVI }

        var entries: [(String, String)] = []

        // Walk top-level RIFF children: read each 8-byte chunk header, only
        // slurp the body when it's a LIST/INFO. AVI's huge `movi` chunk is
        // skipped over with a single seek().
        var pos: UInt64 = 12
        while pos + 8 <= fileSize {
            if summaryOnly { try Task.checkCancellation() }
            try handle.seek(toOffset: pos)
            let chdr = handle.readData(ofLength: 8)
            guard chdr.count == 8 else { break }
            let id = String(data: chdr.subdata(in: 0..<4), encoding: .ascii) ?? ""
            let size = UInt64(leU32(chdr, 4))
            let payloadStart = pos + 8
            let payloadEnd = min(payloadStart + size, fileSize)
            if id == "LIST", payloadEnd - payloadStart >= 4 {
                // Peek the 4-byte LIST type.
                let listTypeData = handle.readData(ofLength: 4)
                let listType = String(data: listTypeData, encoding: .ascii) ?? ""
                if listType == "INFO" {
                    if summaryOnly {
                        var p = payloadStart + 4
                        while p + 8 <= payloadEnd {
                            try Task.checkCancellation()
                            try handle.seek(toOffset: p)
                            let header = handle.readData(ofLength: 8)
                            guard header.count == 8 else { break }
                            let id = String(data: header.prefix(4), encoding: .ascii) ?? ""
                            let size = UInt64(leU32(header, 4))
                            let end = min(p + 8 + size, payloadEnd)
                            if let key = infoIdToKey[id],
                               key == "TITLE" || key == "TRACKNUMBER" || key == "TRACKTOTAL" {
                                var chunk = header
                                chunk.append(handle.readData(ofLength: Int(end - p - 8)))
                                entries.append(contentsOf: decodeInfoList(chunk, start: 0, end: chunk.count))
                            }
                            p = end + (size & 1)
                        }
                    } else {
                        let bodyLen = Int(payloadEnd - payloadStart - 4)
                        let body = handle.readData(ofLength: bodyLen)
                        entries.append(contentsOf:
                            decodeInfoList(body, start: 0, end: body.count))
                    }
                }
            }
            // pad byte if size is odd
            pos = payloadEnd + (size & 1)
        }
        return AVIFile(url: url, entries: entries)
    }

    private static func decodeInfoList(_ data: Data, start: Int, end: Int)
        -> [(String, String)]
    {
        var out: [(String, String)] = []
        var p = start
        while p + 8 <= end {
            let id = String(data: data.subdata(in: p..<p+4), encoding: .ascii) ?? ""
            let size = Int(leU32(data, p + 4))
            let valueEnd = min(p + 8 + size, end)
            var payload = data.subdata(in: p+8..<valueEnd)
            // Trim trailing NULs.
            while let last = payload.last, last == 0 { payload.removeLast() }
            if let key = infoIdToKey[id],
               let value = String(data: payload, encoding: .utf8),
               !value.isEmpty {
                out.append((key, value))
            }
            p = valueEnd + (size & 1)
        }
        return out
    }

    // MARK: - Write

    static func write(url: URL,
                      entries: [(key: String, value: String)]) throws {
        let source = try FileHandle(forReadingFrom: url)
        defer { try? source.close() }
        let fileSize = try source.seekToEnd()
        try source.seek(toOffset: 0)
        let header = try source.read(upToCount: 12) ?? Data()
        guard header.count == 12,
              header[0] == 0x52, header[1] == 0x49,
              header[2] == 0x46, header[3] == 0x46
        else { throw AVIError.notAVI }

        try IOStreaming.writeAtomically(to: url) { tmp in
            let destination = try FileHandle(forWritingTo: tmp)
            defer { try? destination.close() }
            try destination.write(contentsOf: header)

            var p: UInt64 = 12
            while p + 8 <= fileSize {
                try source.seek(toOffset: p)
                let chunkHeader = try source.read(upToCount: 8) ?? Data()
                guard chunkHeader.count == 8 else { throw AVIError.truncated }
                let id = String(data: chunkHeader.prefix(4), encoding: .ascii) ?? ""
                let size = UInt64(leU32(chunkHeader, 4))
                let payloadStart = p + 8
                let payloadEnd = min(payloadStart + size, fileSize)
                let chunkEnd = min(payloadEnd + (size & 1), fileSize)
                var skip = false
                if id == "LIST", payloadEnd - payloadStart >= 4 {
                    let listType = try source.read(upToCount: 4) ?? Data()
                    skip = listType == Data("INFO".utf8)
                }
                if !skip {
                    try source.seek(toOffset: p)
                    try IOStreaming.stream(from: source, into: destination,
                                           byteCount: chunkEnd - p)
                }
                p = chunkEnd
            }

            try destination.write(contentsOf: buildInfoList(entries: entries))
            let outputSize = try destination.offset()
            guard let riffSize = UInt32(exactly: outputSize - 8) else {
                throw NSError(domain: "MediaTagger.AVI", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "AVI exceeds the RIFF size limit"])
            }
            try destination.seek(toOffset: 4)
            try destination.write(contentsOf: leU32Bytes(riffSize))
        }
    }

    private static func buildInfoList(entries: [(key: String, value: String)]) -> Data {
        // Combine track/disc number+total into "n/total" strings (RIFF INFO
        // uses one IPRT for the track number; total is conventionally appended
        // with a slash, mirroring ID3 TRCK behaviour).
        var dict: [String: String] = [:]
        var order: [String] = []
        for (k, v) in entries where !v.isEmpty {
            let key = k.uppercased()
            if dict[key] == nil { order.append(key) }
            dict[key] = v
        }
        var trackStr: String?
        if let n = dict["TRACKNUMBER"] {
            trackStr = (dict["TRACKTOTAL"]).map { "\(n)/\($0)" } ?? n
        }
        // Note: the standard RIFF INFO set has no canonical disc-number chunk,
        // so DISCNUMBER / DISCTOTAL are silently dropped on AVI write.

        var inner = Data()
        inner.append(Data("INFO".utf8))
        for key in order {
            switch key {
            case "TRACKNUMBER", "TRACKTOTAL", "DISCNUMBER", "DISCTOTAL":
                continue // emitted below / dropped
            default:
                if let chunkID = keyToInfoId[key], let v = dict[key] {
                    inner.append(infoChunk(id: chunkID, value: v))
                }
            }
        }
        if let v = trackStr { inner.append(infoChunk(id: "IPRT", value: v)) }

        var out = Data()
        out.append(Data("LIST".utf8))
        out.append(leU32Bytes(UInt32(inner.count)))
        out.append(inner)
        if inner.count & 1 == 1 { out.append(0) }
        return out
    }

    private static func infoChunk(id: String, value: String) -> Data {
        // NUL-terminated UTF-8, padded to even length.
        var payload = Data(value.utf8)
        payload.append(0)
        var d = Data()
        d.append(Data(id.utf8))
        d.append(leU32Bytes(UInt32(payload.count)))
        d.append(payload)
        if payload.count & 1 == 1 { d.append(0) }
        return d
    }

    // MARK: - Tag mappings

    /// RIFF INFO 4CC → Vorbis-style key.
    static let infoIdToKey: [String: String] = [
        "INAM": "TITLE",
        "IART": "ARTIST",
        "IPRD": "ALBUM",
        "ICRD": "DATE",
        "IGNR": "GENRE",
        "ICMT": "COMMENT",
        "IMUS": "COMPOSER",
        "IPRT": "TRACKNUMBER",   // sometimes "n/total"
        "ITRK": "TRACKNUMBER",
        "ISFT": "ENCODER",
        "ICOP": "COPYRIGHT",
    ]
    static let keyToInfoId: [String: String] = [
        "TITLE":     "INAM",
        "ARTIST":    "IART",
        "ALBUM":     "IPRD",
        "DATE":      "ICRD",
        "GENRE":     "IGNR",
        "COMMENT":   "ICMT",
        "COMPOSER":  "IMUS",
        "ENCODER":   "ISFT",
        "COPYRIGHT": "ICOP",
        // TRACKNUMBER handled specially (combined with TRACKTOTAL → IPRT)
    ]
}

// MARK: - helpers (file-private)

fileprivate func leU32(_ d: Data, _ p: Int) -> UInt32 {
    UInt32(d[p]) | (UInt32(d[p+1]) << 8) |
    (UInt32(d[p+2]) << 16) | (UInt32(d[p+3]) << 24)
}
fileprivate func leU32Bytes(_ v: UInt32) -> Data {
    Data([UInt8(v        & 0xFF), UInt8(v >> 8  & 0xFF),
          UInt8(v >> 16 & 0xFF), UInt8(v >> 24 & 0xFF)])
}
