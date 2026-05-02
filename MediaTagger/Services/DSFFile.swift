import Foundation

/// Native DSF (DSD Stream File) tag reader & writer.
///
/// Layout per Sony's DSF spec:
///   DSD chunk  (28 bytes):
///     [0..4)   "DSD "
///     [4..12)  chunk size (LE u64) = 28
///     [12..20) total file size (LE u64)
///     [20..28) metadata pointer (LE u64) — file offset of ID3v2 tag, or 0
///   fmt chunk  (52 bytes):  "fmt " + size + format/sample-rate/etc.
///   data chunk (variable):  "data" + size + DSD samples
///   [optional ID3v2 tag at file end, located by metadataPointer]
///
/// We never touch the audio. On write we (re)build the ID3v2 tag via the
/// existing MP3 writer code, append it after the data chunk, and patch the
/// DSD chunk's `total file size` and `metadata pointer` fields.
enum DSFError: Error, LocalizedError {
    case notDSF
    case truncated
    var errorDescription: String? {
        switch self {
        case .notDSF:     return "File is not a valid DSF container"
        case .truncated:  return "DSF file is truncated"
        }
    }
}

struct DSFFile {

    let url: URL
    /// Raw payload of the embedded ID3v2 tag (if any).
    let id3Tag: Data?
    /// Stream-level audio properties read from the DSD/fmt chunks.
    let techInfo: MediaTechnicalInfo

    // MARK: - Read

    /// Read the embedded ID3v2 tag from a DSF file.
    ///
    /// Streams via `FileHandle` so we never pay a multi-GB mmap (or full
    /// file copy on network volumes) for a DSD album just to fetch a few
    /// KB of ID3 tag. Total bytes read: 80-byte DSD+fmt header + tag body.
    static func read(_ url: URL) throws -> DSFFile {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let fileSize = (try? handle.seekToEnd()) ?? 0
        try handle.seek(toOffset: 0)

        // 28-byte DSD chunk + 52-byte fmt chunk = 80 bytes total.
        let header = handle.readData(ofLength: 80)
        guard header.count >= 28,
              header[0] == 0x44, header[1] == 0x53,
              header[2] == 0x44, header[3] == 0x20
        else { throw DSFError.notDSF }                              // "DSD "

        let metaPtr = leU64(header, 20)

        // Parse fmt chunk for tech info (best-effort — missing/short header
        // is not fatal, we just return whatever fields we managed to read).
        var tech = MediaTechnicalInfo()
        tech.container = "DSF"
        tech.codec = "DSD"
        tech.isDSD = true
        if header.count >= 80,
           header[28] == 0x66, header[29] == 0x6D,
           header[30] == 0x74, header[31] == 0x20 {              // "fmt "
            let channelNum  = leU32(header, 48)
            let sampleFreq  = leU32(header, 52)
            let bitsPer     = leU32(header, 56)
            let sampleCount = leU64(header, 60)
            tech.channels = Int(channelNum)
            tech.sampleRate = Double(sampleFreq)
            tech.bitsPerSample = Int(bitsPer)
            if sampleFreq > 0 {
                tech.durationSeconds = Double(sampleCount) / Double(sampleFreq)
            }
            if sampleFreq > 0 && channelNum > 0 {
                tech.bitrate = Double(sampleFreq) * Double(channelNum) * Double(bitsPer)
            }
        }

        guard metaPtr > 0, metaPtr < fileSize else {
            return DSFFile(url: url, id3Tag: nil, techInfo: tech)
        }
        try handle.seek(toOffset: metaPtr)
        let blob = handle.readData(ofLength: Int(fileSize - metaPtr))
        return DSFFile(url: url, id3Tag: blob, techInfo: tech)
    }

    /// Decode embedded ID3v2 tag (if any) into Vorbis-style entries + cover.
    func decoded() -> (entries: [(key: String, value: String)],
                       cover: (data: Data, mime: String)?) {
        guard let blob = id3Tag,
              let parsed = try? ID3v2File.parse(blob, url: url)
        else { return ([], nil) }
        return parsed.decoded()
    }

    // MARK: - Write

    static func write(url: URL,
                      entries: [(key: String, value: String)],
                      cover: (data: Data, mime: String)?) throws {
        let original = try Data(contentsOf: url, options: .mappedIfSafe)
        guard original.count >= 28,
              original[0] == 0x44, original[1] == 0x53,
              original[2] == 0x44, original[3] == 0x20
        else { throw DSFError.notDSF }

        let oldMetaPtr = leU64(original, 20)
        // Truncate any existing ID3 tag — the prefix up to oldMetaPtr is the
        // DSD/fmt/data chunks we want to keep verbatim. If no tag was present,
        // keep everything (which is the same as the file body).
        let bodyEnd = (oldMetaPtr > 0 && oldMetaPtr <= UInt64(original.count))
            ? Int(oldMetaPtr) : original.count
        var out = original.subdata(in: 0..<bodyEnd)

        // Build fresh ID3v2 tag bytes (mirror ID3v2File.write's frame-building).
        let id3 = encodedID3(entries: entries, cover: cover)
        let newMetaPtr = UInt64(out.count)
        out.append(id3)

        // Patch DSD chunk header: total file size at [12..20), metadata pointer at [20..28).
        out.replaceSubrange(12..<20, with: leU64Bytes(UInt64(out.count)))
        out.replaceSubrange(20..<28, with: leU64Bytes(newMetaPtr))

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

// MARK: - LE helpers (file-private)

fileprivate func leU64(_ d: Data, _ p: Int) -> UInt64 {
    var v: UInt64 = 0
    for i in 0..<8 { v |= UInt64(d[p + i]) << (8 * i) }
    return v
}

fileprivate func leU32(_ d: Data, _ p: Int) -> UInt32 {
    UInt32(d[p]) | (UInt32(d[p + 1]) << 8) | (UInt32(d[p + 2]) << 16) | (UInt32(d[p + 3]) << 24)
}

fileprivate func leU64Bytes(_ v: UInt64) -> Data {
    var out = [UInt8](repeating: 0, count: 8)
    for i in 0..<8 { out[i] = UInt8((v >> (8 * i)) & 0xFF) }
    return Data(out)
}
