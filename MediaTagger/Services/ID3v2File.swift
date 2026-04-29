import Foundation

/// Native ID3v2 reader & writer.
///
/// Supports reading ID3v2.3 and ID3v2.4 text frames, COMM (comment) and APIC
/// (picture). Writes ID3v2.3 with UTF-16 (BOM) encoding for maximum
/// compatibility, regardless of the original tag version.
///
/// The on-disk layout we touch:
///   [optional ID3v2 tag at the start] [audio frames] [optional ID3v1 trailer]
/// We never disturb the audio or the ID3v1 trailer.

enum ID3Error: Error, LocalizedError {
    case truncated
    case writeFailed(String)
    var errorDescription: String? {
        switch self {
        case .truncated: return "MP3 file is truncated"
        case .writeFailed(let s): return "MP3 write failed: \(s)"
        }
    }
}

/// In-memory representation of an MP3 file's ID3v2 tag plus the rest of the
/// file body (audio + optional ID3v1 trailer) preserved verbatim.
struct ID3v2File {
    let url: URL
    /// Frames in iteration order. Frame IDs are normalised to 4-char ASCII
    /// (v2.2 not supported — vanishingly rare).
    var frames: [ID3Frame]
    /// Bytes after the ID3v2 tag (audio + ID3v1 if present).
    var body: Data

    // MARK: Read

    static func read(_ url: URL) throws -> ID3v2File {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try parse(data, url: url)
    }

    static func parse(_ data: Data, url: URL) throws -> ID3v2File {
        guard data.count >= 10 else { throw ID3Error.truncated }
        let hasID3 = data[0] == 0x49 && data[1] == 0x44 && data[2] == 0x33  // "ID3"
        guard hasID3 else {
            // No ID3v2 tag at all — return an empty one and treat the whole file as body.
            return ID3v2File(url: url, frames: [], body: data)
        }
        let major = data[3]
        let _    = data[4]   // revision (ignored)
        let flags = data[5]
        let tagSize = Int(syncsafe(data[6], data[7], data[8], data[9]))
        guard data.count >= 10 + tagSize else { throw ID3Error.truncated }

        var p = 10
        // Skip extended header if present.
        if flags & 0x40 != 0, p + 4 <= data.count {
            let extSize: Int
            if major >= 4 {
                extSize = Int(syncsafe(data[p], data[p+1], data[p+2], data[p+3]))
            } else {
                extSize = Int(beUInt32(data, p)) + 4 // v2.3 includes the size field
            }
            p += extSize
        }

        let end = 10 + tagSize
        var frames: [ID3Frame] = []
        while p + 10 <= end {
            // A null frame ID indicates start of padding.
            if data[p] == 0 { break }
            let id = String(bytes: data[p..<(p+4)], encoding: .ascii) ?? "????"
            let size: Int
            if major >= 4 {
                size = Int(syncsafe(data[p+4], data[p+5], data[p+6], data[p+7]))
            } else {
                size = Int(beUInt32(data, p+4))
            }
            // frame flags at p+8, p+9 (2 bytes) — not honoured for writing
            let dataStart = p + 10
            guard dataStart + size <= end else { break }
            let frameData = data.subdata(in: dataStart..<(dataStart + size))
            frames.append(ID3Frame(id: id, data: frameData))
            p = dataStart + size
        }

        let body = data.subdata(in: end..<data.count)
        return ID3v2File(url: url, frames: frames, body: body)
    }

    // MARK: High-level accessors (Vorbis-style keys)

    static let frameByKey: [String: String] = [
        "TITLE":       "TIT2",
        "ARTIST":      "TPE1",
        "ALBUMARTIST": "TPE2",
        "ALBUM":       "TALB",
        "DATE":        "TDRC",   // v2.4 spelling; we also write TYER on v2.3 below
        "GENRE":       "TCON",
        "COMPOSER":    "TCOM",
        "COMMENT":     "COMM",
        // TRACKNUMBER/TRACKTOTAL collapse to "n/total" in TRCK
        // DISCNUMBER/DISCTOTAL collapse to "n/total" in TPOS
    ]

    static let keyByFrame: [String: String] = [
        "TIT2": "TITLE",
        "TPE1": "ARTIST",
        "TPE2": "ALBUMARTIST",
        "TALB": "ALBUM",
        "TDRC": "DATE",
        "TYER": "DATE",
        "TCON": "GENRE",
        "TCOM": "COMPOSER",
        "COMM": "COMMENT",
    ]

    /// Decodes all known frames into Vorbis-style key/value pairs (TRCK/TPOS
    /// split into number/total). Picture frame returned separately.
    func decoded() -> (entries: [(key: String, value: String)], cover: (data: Data, mime: String)?) {
        var out: [(String, String)] = []
        var cover: (Data, String)?

        for f in frames {
            switch f.id {
            case "APIC":
                if let pic = ID3Frame.decodeAPIC(f.data) { cover = (pic.data, pic.mime) }
            case "TRCK":
                if let s = ID3Frame.decodeText(f.data) {
                    let (n, t) = splitSlash(s)
                    out.append(("TRACKNUMBER", n))
                    if let t { out.append(("TRACKTOTAL", t)) }
                }
            case "TPOS":
                if let s = ID3Frame.decodeText(f.data) {
                    let (n, t) = splitSlash(s)
                    out.append(("DISCNUMBER", n))
                    if let t { out.append(("DISCTOTAL", t)) }
                }
            case "COMM":
                if let s = ID3Frame.decodeCOMM(f.data) {
                    out.append(("COMMENT", s))
                }
            default:
                if let key = Self.keyByFrame[f.id], let s = ID3Frame.decodeText(f.data) {
                    // Avoid duplicate DATE if both TDRC and TYER exist.
                    if key == "DATE" && out.contains(where: { $0.0 == "DATE" }) { continue }
                    out.append((key, s))
                }
            }
        }
        return (out, cover)
    }

    // MARK: Write

    /// Replaces ID3v2 frames with ones derived from `entries` and `cover`,
    /// then writes the file back. `entries` are Vorbis-style keys; unknown
    /// keys become TXXX user-defined frames.
    static func write(
        url: URL,
        entries: [(key: String, value: String)],
        cover: (data: Data, mime: String)?
    ) throws {
        // Read existing body so audio + ID3v1 are preserved.
        let existing = try ID3v2File.read(url)
        let body = existing.body

        // Build frames.
        var newFrames: [ID3Frame] = []

        // Collect track/disc number+total before emitting.
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
                // Write both TYER and TDRC for compatibility.
                newFrames.append(ID3Frame(id: "TYER", data: ID3Frame.encodeText(value)))
                newFrames.append(ID3Frame(id: "TDRC", data: ID3Frame.encodeText(value)))
            default:
                if let frameId = frameByKey[key] {
                    newFrames.append(ID3Frame(id: frameId, data: ID3Frame.encodeText(value)))
                } else {
                    // Unknown standard key -> TXXX user-defined text frame.
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

        let tag = encodeTag(frames: newFrames, padding: 1024)
        var out = Data()
        out.reserveCapacity(tag.count + body.count)
        out.append(tag)
        out.append(body)

        try atomicWrite(out, to: url)
    }

    /// Encodes an ID3v2.3 tag (header + frames + padding).
    static func encodeTag(frames: [ID3Frame], padding: Int) -> Data {
        var framesData = Data()
        for f in frames {
            // v2.3 frame: 4-byte ID + 4-byte BE size (NOT syncsafe) + 2 flags + data
            framesData.append(Data(f.id.utf8))
            framesData.append(beUInt32Bytes(UInt32(f.data.count)))
            framesData.append(contentsOf: [0x00, 0x00])
            framesData.append(f.data)
        }
        let totalContent = framesData.count + padding
        var out = Data()
        out.append(contentsOf: [0x49, 0x44, 0x33])  // "ID3"
        out.append(contentsOf: [0x03, 0x00])        // v2.3.0
        out.append(0x00)                            // flags
        out.append(syncsafeBytes(UInt32(totalContent)))
        out.append(framesData)
        out.append(Data(count: padding))
        return out
    }

    private static func atomicWrite(_ data: Data, to url: URL) throws {
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        do {
            try data.write(to: tmp, options: .atomic)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw ID3Error.writeFailed(error.localizedDescription)
        }
    }
}

// MARK: - Frame

struct ID3Frame {
    let id: String   // 4-char ASCII
    let data: Data

    // MARK: Decoders

    /// Decodes a text-information frame ("T***"), honouring its encoding byte.
    static func decodeText(_ d: Data) -> String? {
        guard !d.isEmpty else { return nil }
        let enc = d[d.startIndex]
        let payload = d.dropFirst()
        let raw = decodeString(payload, encoding: enc) ?? ""
        // Some encoders embed multiple values separated by NUL.
        return raw.split(separator: "\0").first.map(String.init) ?? raw
    }

    static func decodeCOMM(_ d: Data) -> String? {
        guard d.count >= 5 else { return nil }
        let enc = d[d.startIndex]
        // Skip 3-byte language code.
        var p = d.startIndex + 4
        // Short description (terminated string in `enc`)
        let (_, after) = readTerminatedString(d, from: p, encoding: enc)
        p = after
        guard p <= d.endIndex else { return nil }
        let raw = decodeString(d.subdata(in: p..<d.endIndex), encoding: enc) ?? ""
        // Trim trailing null terminators that some encoders leave in the payload.
        return raw.trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
    }

    static func decodeAPIC(_ d: Data) -> (data: Data, mime: String, type: UInt8)? {
        guard d.count >= 4 else { return nil }
        let enc = d[d.startIndex]
        var p = d.startIndex + 1
        // MIME (latin-1, null-terminated)
        guard let nul = d[p..<d.endIndex].firstIndex(of: 0) else { return nil }
        let mime = String(data: d.subdata(in: p..<nul), encoding: .isoLatin1) ?? ""
        p = nul + 1
        guard p < d.endIndex else { return nil }
        let picType = d[p]
        p += 1
        let (_, after) = readTerminatedString(d, from: p, encoding: enc)
        p = after
        guard p <= d.endIndex else { return nil }
        return (d.subdata(in: p..<d.endIndex), mime, picType)
    }

    // MARK: Encoders (we always write encoding 1 = UTF-16 with BOM)

    static func encodeText(_ s: String) -> Data {
        var d = Data()
        d.append(0x01)                       // encoding
        d.append(utf16WithBOM(s))
        return d
    }

    static func encodeCOMM(_ s: String) -> Data {
        var d = Data()
        d.append(0x01)                       // encoding
        d.append(contentsOf: [0x65, 0x6E, 0x67]) // "eng" language
        d.append(utf16WithBOM(""))           // empty short description (with BOM + terminator)
        d.append(utf16WithBOM(s))
        return d
    }

    static func encodeTXXX(description: String, value: String) -> Data {
        var d = Data()
        d.append(0x01)
        d.append(utf16WithBOM(description))
        d.append(utf16WithBOM(value))
        return d
    }

    static func encodeAPIC(data: Data, mime: String) -> Data {
        var d = Data()
        d.append(0x01)                       // encoding (for description)
        d.append(Data(mime.utf8))            // MIME (latin-1/ascii)
        d.append(0x00)                       // null
        d.append(0x03)                       // picture type: front cover
        d.append(utf16WithBOM(""))           // empty description (BOM + 0x0000)
        d.append(data)
        return d
    }
}

// MARK: - Helpers

private func syncsafe(_ b0: UInt8, _ b1: UInt8, _ b2: UInt8, _ b3: UInt8) -> UInt32 {
    UInt32(b0 & 0x7F) << 21 | UInt32(b1 & 0x7F) << 14 | UInt32(b2 & 0x7F) << 7 | UInt32(b3 & 0x7F)
}

private func syncsafeBytes(_ v: UInt32) -> Data {
    Data([
        UInt8((v >> 21) & 0x7F),
        UInt8((v >> 14) & 0x7F),
        UInt8((v >> 7)  & 0x7F),
        UInt8(v & 0x7F)
    ])
}

private func beUInt32(_ d: Data, _ p: Int) -> UInt32 {
    UInt32(d[p]) << 24 | UInt32(d[p+1]) << 16 | UInt32(d[p+2]) << 8 | UInt32(d[p+3])
}

private func beUInt32Bytes(_ v: UInt32) -> Data {
    Data([
        UInt8((v >> 24) & 0xFF),
        UInt8((v >> 16) & 0xFF),
        UInt8((v >> 8)  & 0xFF),
        UInt8(v & 0xFF)
    ])
}

private func splitSlash(_ s: String) -> (String, String?) {
    if let i = s.firstIndex(of: "/") {
        return (String(s[..<i]), String(s[s.index(after: i)...]))
    }
    return (s, nil)
}

private func utf16WithBOM(_ s: String) -> Data {
    var d = Data([0xFF, 0xFE])  // little-endian BOM
    for u in s.utf16 {
        d.append(UInt8(u & 0xFF))
        d.append(UInt8((u >> 8) & 0xFF))
    }
    // Null terminator (2 bytes for UTF-16).
    d.append(contentsOf: [0x00, 0x00])
    return d
}

private func decodeString(_ d: Data, encoding: UInt8) -> String? {
    switch encoding {
    case 0:
        return String(data: d, encoding: .isoLatin1)
    case 1:
        // UTF-16 with BOM
        if d.count >= 2 {
            let bom = (d[d.startIndex], d[d.startIndex + 1])
            let payload = d.dropFirst(2)
            if bom == (0xFF, 0xFE) {
                return String(data: payload, encoding: .utf16LittleEndian)
            } else if bom == (0xFE, 0xFF) {
                return String(data: payload, encoding: .utf16BigEndian)
            }
        }
        return String(data: d, encoding: .utf16)
    case 2:
        return String(data: d, encoding: .utf16BigEndian)
    case 3:
        return String(data: d, encoding: .utf8)
    default:
        return String(data: d, encoding: .isoLatin1)
    }
}

/// Reads a string up to (and including) its null terminator from `data` starting at `from`.
/// Returns the decoded string and the index just past the terminator.
private func readTerminatedString(_ data: Data, from start: Int, encoding: UInt8) -> (String, Int) {
    if encoding == 1 || encoding == 2 {
        var p = start
        while p + 1 < data.endIndex {
            if data[p] == 0 && data[p+1] == 0 { break }
            p += 2
        }
        let s = decodeString(data.subdata(in: start..<p), encoding: encoding) ?? ""
        return (s, min(p + 2, data.endIndex))
    } else {
        var p = start
        while p < data.endIndex && data[p] != 0 { p += 1 }
        let s = decodeString(data.subdata(in: start..<p), encoding: encoding) ?? ""
        return (s, min(p + 1, data.endIndex))
    }
}
