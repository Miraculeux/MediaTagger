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
    /// Raw payload of the "ID3 " chunk if one exists (a full ID3v2 tag).
    let id3Chunk: Data?

    // MARK: - Read

    static func read(_ url: URL) throws -> AIFFFile {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count >= 12 else { throw AIFFError.truncated }
        guard data[0] == 0x46, data[1] == 0x4F, data[2] == 0x52, data[3] == 0x4D
        else { throw AIFFError.notAIFF }                           // "FORM"
        let formType = String(data: data.subdata(in: 8..<12), encoding: .ascii) ?? ""
        guard formType == "AIFF" || formType == "AIFC" else { throw AIFFError.notAIFF }

        var p = 12
        var id3: Data?
        while p + 8 <= data.count {
            let id = String(data: data.subdata(in: p..<p+4), encoding: .ascii) ?? ""
            let size = Int(beU32(data, p + 4))
            let payloadStart = p + 8
            let payloadEnd = payloadStart + size
            guard payloadEnd <= data.count else { break }
            if id == "ID3 " {
                id3 = data.subdata(in: payloadStart..<payloadEnd)
            }
            // Advance past payload + 1-byte pad if odd.
            p = payloadEnd + (size & 1)
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
        let original = try Data(contentsOf: url, options: .mappedIfSafe)
        guard original.count >= 12,
              original[0] == 0x46, original[1] == 0x4F,
              original[2] == 0x52, original[3] == 0x4D
        else { throw AIFFError.notAIFF }
        let formType = original.subdata(in: 8..<12)

        // Build the new ID3v2 tag payload by reusing the MP3 path.
        let newID3 = encodedID3(entries: entries, cover: cover)

        // Rebuild chunk list: keep every non-ID3 chunk's bytes (including its
        // header and pad byte), and emit our new "ID3 " chunk last.
        var chunksOut = Data()
        var p = 12
        while p + 8 <= original.count {
            let id = String(data: original.subdata(in: p..<p+4), encoding: .ascii) ?? ""
            let size = Int(beU32(original, p + 4))
            let payloadEnd = p + 8 + size
            guard payloadEnd <= original.count else { break }
            let chunkEnd = payloadEnd + (size & 1)        // include pad byte if any
            if id != "ID3 " {
                chunksOut.append(original.subdata(in: p..<min(chunkEnd, original.count)))
            }
            p = chunkEnd
        }

        // Append new ID3 chunk.
        chunksOut.append(Data("ID3 ".utf8))
        chunksOut.append(beU32Bytes(UInt32(newID3.count)))
        chunksOut.append(newID3)
        if newID3.count & 1 == 1 { chunksOut.append(0) }   // pad to even

        // Final FORM size = 4 ("AIFF"/"AIFC") + chunks.
        var out = Data()
        out.append(Data("FORM".utf8))
        out.append(beU32Bytes(UInt32(4 + chunksOut.count)))
        out.append(formType)
        out.append(chunksOut)

        try atomicWrite(out, to: url)
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

    private static func atomicWrite(_ data: Data, to url: URL) throws {
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        do {
            try data.write(to: tmp, options: .atomic)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
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
