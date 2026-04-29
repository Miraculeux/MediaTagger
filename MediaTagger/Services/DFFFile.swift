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

    // MARK: - Read

    static func read(_ url: URL) throws -> DFFFile {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count >= 16,
              data[0] == 0x46, data[1] == 0x52, data[2] == 0x4D, data[3] == 0x38
        else { throw DFFError.notDFF }                              // "FRM8"
        let formType = String(data: data.subdata(in: 12..<16), encoding: .ascii) ?? ""
        guard formType == "DSD " else { throw DFFError.notDFF }

        // Walk top-level chunks of FRM8 starting after the 16-byte header.
        var p = 16
        var id3: Data?
        while p + 12 <= data.count {
            let id = String(data: data.subdata(in: p..<p+4), encoding: .ascii) ?? ""
            let size = Int(beU64(data, p + 4))
            let payloadStart = p + 12
            let payloadEnd = min(payloadStart + size, data.count)
            if id == "ID3 " {
                id3 = data.subdata(in: payloadStart..<payloadEnd)
            }
            p = payloadEnd + (size & 1)        // 1-byte pad if odd
        }
        return DFFFile(url: url, id3Chunk: id3)
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
    static func write(url: URL,
                      entries: [(key: String, value: String)],
                      cover: (data: Data, mime: String)?) throws {
        let original = try Data(contentsOf: url, options: .mappedIfSafe)
        guard original.count >= 16,
              original[0] == 0x46, original[1] == 0x52,
              original[2] == 0x4D, original[3] == 0x38
        else { throw DFFError.notDFF }
        let formType = original.subdata(in: 12..<16)

        let newID3 = encodedID3(entries: entries, cover: cover)

        // Rebuild chunks: keep every non-ID3 chunk's bytes verbatim, then
        // append a fresh ID3 chunk last.
        var chunksOut = Data()
        var p = 16
        while p + 12 <= original.count {
            let id = String(data: original.subdata(in: p..<p+4), encoding: .ascii) ?? ""
            let size = Int(beU64(original, p + 4))
            let payloadEnd = p + 12 + size
            guard payloadEnd <= original.count else { break }
            let chunkEnd = payloadEnd + (size & 1)
            if id != "ID3 " {
                chunksOut.append(original.subdata(in: p..<min(chunkEnd, original.count)))
            }
            p = chunkEnd
        }

        chunksOut.append(Data("ID3 ".utf8))
        chunksOut.append(beU64Bytes(UInt64(newID3.count)))
        chunksOut.append(newID3)
        if newID3.count & 1 == 1 { chunksOut.append(0) }

        // FRM8 size = 4 (form type) + chunksOut.count.
        var out = Data()
        out.append(Data("FRM8".utf8))
        out.append(beU64Bytes(UInt64(4 + chunksOut.count)))
        out.append(formType)                                         // "DSD "
        out.append(chunksOut)

        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        try out.write(to: tmp, options: .atomic)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
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
