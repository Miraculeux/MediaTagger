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

    static func read(_ url: URL) throws -> AVIFile {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count >= 12,
              data[0] == 0x52, data[1] == 0x49, data[2] == 0x46, data[3] == 0x46
        else { throw AVIError.notAVI }                              // "RIFF"
        let formType = String(data: data.subdata(in: 8..<12), encoding: .ascii) ?? ""
        guard formType == "AVI " else { throw AVIError.notAVI }

        var entries: [(String, String)] = []
        // Walk top-level RIFF children. Recurse one level into LIST chunks
        // looking for an INFO list.
        var p = 12
        while p + 8 <= data.count {
            let id = String(data: data.subdata(in: p..<p+4), encoding: .ascii) ?? ""
            let size = Int(leU32(data, p + 4))
            let payloadStart = p + 8
            let payloadEnd = min(payloadStart + size, data.count)
            if id == "LIST", payloadEnd - payloadStart >= 4 {
                let listType = String(data: data.subdata(in: payloadStart..<payloadStart+4),
                                      encoding: .ascii) ?? ""
                if listType == "INFO" {
                    entries.append(contentsOf:
                        decodeInfoList(data, start: payloadStart + 4, end: payloadEnd))
                }
            }
            // pad byte if size is odd
            p = payloadEnd + (size & 1)
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
        let original = try Data(contentsOf: url, options: .mappedIfSafe)
        guard original.count >= 12,
              original[0] == 0x52, original[1] == 0x49,
              original[2] == 0x46, original[3] == 0x46
        else { throw AVIError.notAVI }
        let formType = original.subdata(in: 8..<12)

        // Rebuild children, dropping any existing LIST/INFO.
        var kept = Data()
        var p = 12
        while p + 8 <= original.count {
            let id = String(data: original.subdata(in: p..<p+4), encoding: .ascii) ?? ""
            let size = Int(leU32(original, p + 4))
            let payloadStart = p + 8
            let payloadEnd = min(payloadStart + size, original.count)
            let chunkEnd = min(payloadEnd + (size & 1), original.count)
            var skip = false
            if id == "LIST", payloadEnd - payloadStart >= 4 {
                let listType = String(data: original.subdata(in: payloadStart..<payloadStart+4),
                                      encoding: .ascii) ?? ""
                if listType == "INFO" { skip = true }
            }
            if !skip {
                kept.append(original.subdata(in: p..<chunkEnd))
            }
            p = chunkEnd
        }

        // Build new LIST/INFO from entries.
        let infoList = buildInfoList(entries: entries)
        kept.append(infoList)

        var out = Data()
        out.append(Data("RIFF".utf8))
        out.append(leU32Bytes(UInt32(4 + kept.count)))   // file size minus header
        out.append(formType)                              // "AVI "
        out.append(kept)

        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        try out.write(to: tmp, options: .atomic)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
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
