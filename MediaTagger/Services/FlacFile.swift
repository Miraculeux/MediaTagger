import Foundation

/// Native FLAC metadata reader & writer.
///
/// FLAC stream layout:
///   "fLaC" (4 bytes) | metadata blocks | audio frames
///
/// Each metadata block:
///   1 byte  : <last(1)><type(7)>
///   3 bytes : data length (BE)
///   N bytes : data
///
/// Block types we care about:
///   0 = STREAMINFO  (mandatory, first)
///   4 = VORBIS_COMMENT
///   6 = PICTURE
///
/// Vorbis comment encoding is little-endian (per Vorbis spec), unlike the
/// surrounding FLAC framing which is big-endian.
enum FlacError: Error, LocalizedError {
    case notFlac
    case truncated
    case invalidVorbisComment
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .notFlac: return "Not a FLAC file (missing fLaC marker)"
        case .truncated: return "FLAC file is truncated"
        case .invalidVorbisComment: return "Malformed Vorbis comment block"
        case .writeFailed(let s): return "FLAC write failed: \(s)"
        }
    }
}

struct FlacBlock {
    var isLast: Bool
    var type: UInt8        // 0..126, 127 reserved
    var data: Data
}

enum FlacBlockType {
    static let streamInfo:    UInt8 = 0
    static let padding:       UInt8 = 1
    static let application:   UInt8 = 2
    static let seekTable:     UInt8 = 3
    static let vorbisComment: UInt8 = 4
    static let cueSheet:      UInt8 = 5
    static let picture:       UInt8 = 6
}

struct FlacFile {
    let url: URL
    var blocks: [FlacBlock]
    /// Offset in the file where the audio frames begin (right after the last metadata block).
    var audioOffset: Int
    /// Optional ID3v2 tag bytes that appear before the `fLaC` marker. Some
    /// taggers prepend an ID3v2 tag to FLAC files; we preserve this prefix
    /// verbatim on write so existing data is not lost.
    var id3Prefix: Data = Data()

    // MARK: Reading

    static func read(_ url: URL) throws -> FlacFile {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try parse(data, url: url)
    }

    static func parse(_ data: Data, url: URL) throws -> FlacFile {
        var prefix = Data()
        var startOffset = 0

        // Skip an optional ID3v2 prefix ("ID3" + 2 version + 1 flags + 4 syncsafe size).
        if data.count >= 10,
           data[0] == 0x49, data[1] == 0x44, data[2] == 0x33 {
            let flags = data[5]
            let tagSize = Int(data[6] & 0x7F) << 21
                | Int(data[7] & 0x7F) << 14
                | Int(data[8] & 0x7F) << 7
                | Int(data[9] & 0x7F)
            // Bit 4 of flags indicates a 10-byte footer (ID3v2.4).
            let footer = (flags & 0x10) != 0 ? 10 : 0
            let totalID3 = 10 + tagSize + footer
            guard totalID3 <= data.count else { throw FlacError.truncated }
            prefix = data.subdata(in: 0..<totalID3)
            startOffset = totalID3
        }

        guard startOffset + 4 <= data.count,
              data[startOffset] == 0x66,
              data[startOffset + 1] == 0x4C,
              data[startOffset + 2] == 0x61,
              data[startOffset + 3] == 0x43
        else { throw FlacError.notFlac }

        var blocks: [FlacBlock] = []
        var p = startOffset + 4
        while true {
            guard p + 4 <= data.count else { throw FlacError.truncated }
            let header = data[p]
            let isLast = (header & 0x80) != 0
            let type = header & 0x7F
            let len = (Int(data[p+1]) << 16) | (Int(data[p+2]) << 8) | Int(data[p+3])
            p += 4
            guard p + len <= data.count else { throw FlacError.truncated }
            blocks.append(FlacBlock(isLast: isLast, type: type, data: data.subdata(in: p..<(p+len))))
            p += len
            if isLast { break }
        }
        return FlacFile(url: url, blocks: blocks, audioOffset: p, id3Prefix: prefix)
    }

    // MARK: Vorbis comment

    var vorbisCommentBlockIndex: Int? {
        blocks.firstIndex { $0.type == FlacBlockType.vorbisComment }
    }

    var vorbisComment: VorbisComment {
        get {
            guard let i = vorbisCommentBlockIndex,
                  let vc = try? VorbisComment.decode(blocks[i].data)
            else { return VorbisComment(vendor: "MediaTagger", entries: []) }
            return vc
        }
    }

    mutating func setVorbisComment(_ vc: VorbisComment) {
        let encoded = vc.encode()
        if let i = vorbisCommentBlockIndex {
            blocks[i].data = encoded
        } else {
            // Insert before the last block, mark flags appropriately.
            let newBlock = FlacBlock(isLast: false, type: FlacBlockType.vorbisComment, data: encoded)
            blocks.insert(newBlock, at: max(blocks.count - 1, 0))
        }
    }

    // MARK: Picture

    /// Returns the front-cover (type 3) PICTURE block if present,
    /// otherwise falls back to the first decodable picture block.
    var firstPicture: FlacPicture? {
        var fallback: FlacPicture?
        for b in blocks where b.type == FlacBlockType.picture {
            guard let pic = try? FlacPicture.decode(b.data) else { continue }
            if pic.pictureType == 3 { return pic }
            if fallback == nil { fallback = pic }
        }
        return fallback
    }

    mutating func setFrontCover(_ picture: FlacPicture?) {
        // Replace all PICTURE blocks with a single front cover for maximum compatibility.
        blocks.removeAll { $0.type == FlacBlockType.picture }
        if let picture {
            let data = picture.encode()
            blocks.insert(FlacBlock(isLast: false, type: FlacBlockType.picture, data: data),
                          at: max(blocks.count - 1, 0))
        }
    }

    // MARK: Writing

    /// Serialise blocks back to a `Data` of header+blocks (without audio frames),
    /// fixing the last-block flag and padding the metadata area to minimise
    /// rewriting of audio data when possible.
    func encodeMetadataArea(targetSize: Int? = nil) -> Data {
        var normalized = blocks
        // Strip existing padding; we'll add a single padding block at end.
        normalized.removeAll { $0.type == FlacBlockType.padding }
        for i in normalized.indices { normalized[i].isLast = false }

        var body = Data()
        for b in normalized {
            body.append(encodeBlockHeader(isLast: false, type: b.type, length: b.data.count))
            body.append(b.data)
        }
        let nonPaddingSize = body.count
        let target = targetSize ?? (nonPaddingSize + 4 + 4096) // 4 KiB padding by default
        let paddingPayloadSize = max(0, target - nonPaddingSize - 4)
        body.append(encodeBlockHeader(isLast: true, type: FlacBlockType.padding, length: paddingPayloadSize))
        body.append(Data(count: paddingPayloadSize))
        return body
    }

    private func encodeBlockHeader(isLast: Bool, type: UInt8, length: Int) -> Data {
        var d = Data(count: 4)
        d[0] = (isLast ? 0x80 : 0x00) | (type & 0x7F)
        d[1] = UInt8((length >> 16) & 0xFF)
        d[2] = UInt8((length >> 8) & 0xFF)
        d[3] = UInt8(length & 0xFF)
        return d
    }

    /// Writes the file in-place. If the new metadata area fits within the
    /// existing one (using padding), we patch the metadata bytes directly
    /// via `FileHandle.seek` so multi-GB FLACs don't get rewritten just to
    /// retitle a track. Otherwise we stream the audio frames into a new
    /// temp file alongside the new header and atomically swap it in.
    func write() throws {
        let prefixLen = id3Prefix.count
        let originalMetadataLen = audioOffset - prefixLen - 4 // excluding ID3v2 prefix and "fLaC"

        // Try to fit into existing metadata area: patch bytes in place.
        let inPlace = encodeMetadataArea(targetSize: originalMetadataLen)
        if inPlace.count == originalMetadataLen {
            let h = try FileHandle(forUpdating: url)
            defer { try? h.close() }
            try h.seek(toOffset: UInt64(prefixLen + 4))
            try h.write(contentsOf: inPlace)
            return
        }

        // Otherwise rewrite: stream audio frames into a temp file.
        let area = encodeMetadataArea()
        let fileSize = IOStreaming.fileSize(of: url)
        let audioBytes = fileSize > UInt64(audioOffset) ? fileSize - UInt64(audioOffset) : 0

        try IOStreaming.writeAtomically(to: url) { tmpURL in
            let dest = try FileHandle(forWritingTo: tmpURL)
            defer { try? dest.close() }
            if prefixLen > 0 { try dest.write(contentsOf: id3Prefix) }
            try dest.write(contentsOf: Data([0x66, 0x4C, 0x61, 0x43]))
            try dest.write(contentsOf: area)

            let src = try FileHandle(forReadingFrom: url)
            defer { try? src.close() }
            try src.seek(toOffset: UInt64(audioOffset))
            if audioBytes > 0 {
                try IOStreaming.stream(from: src, into: dest, byteCount: audioBytes)
            }
        }
    }
}

// MARK: - VorbisComment

struct VorbisComment {
    var vendor: String
    var entries: [(key: String, value: String)]

    static func decode(_ data: Data) throws -> VorbisComment {
        var r = LittleEndianReader(data)
        guard let vendorLen = r.readU32() else { throw FlacError.invalidVorbisComment }
        guard let vendorBytes = r.read(Int(vendorLen)) else { throw FlacError.invalidVorbisComment }
        let vendor = String(data: vendorBytes, encoding: .utf8) ?? ""
        guard let count = r.readU32() else { throw FlacError.invalidVorbisComment }
        var entries: [(String, String)] = []
        entries.reserveCapacity(Int(count))
        for _ in 0..<count {
            guard let len = r.readU32(), let bytes = r.read(Int(len)) else {
                throw FlacError.invalidVorbisComment
            }
            let s = String(data: bytes, encoding: .utf8) ?? ""
            if let eq = s.firstIndex(of: "=") {
                let key = String(s[..<eq]).uppercased()
                let value = String(s[s.index(after: eq)...])
                entries.append((key, value))
            } else {
                entries.append((s.uppercased(), ""))
            }
        }
        return VorbisComment(vendor: vendor, entries: entries)
    }

    func encode() -> Data {
        var out = Data()
        let vendorBytes = Data(vendor.utf8)
        out.append(le32(UInt32(vendorBytes.count)))
        out.append(vendorBytes)
        out.append(le32(UInt32(entries.count)))
        for (k, v) in entries {
            let line = "\(k)=\(v)"
            let lb = Data(line.utf8)
            out.append(le32(UInt32(lb.count)))
            out.append(lb)
        }
        return out
    }

    private func le32(_ v: UInt32) -> Data {
        var le = v.littleEndian
        return Data(bytes: &le, count: 4)
    }
}

// MARK: - PICTURE block

struct FlacPicture {
    var pictureType: UInt32  // 3 = front cover
    var mimeType: String
    var description: String
    var width: UInt32
    var height: UInt32
    var depth: UInt32
    var colors: UInt32
    var data: Data

    static func decode(_ d: Data) throws -> FlacPicture {
        var r = BigEndianReader(d)
        guard let type = r.readU32(),
              let mimeLen = r.readU32(),
              let mimeBytes = r.read(Int(mimeLen)),
              let descLen = r.readU32(),
              let descBytes = r.read(Int(descLen)),
              let w = r.readU32(),
              let h = r.readU32(),
              let depth = r.readU32(),
              let colors = r.readU32(),
              let dataLen = r.readU32(),
              let img = r.read(Int(dataLen))
        else { throw FlacError.invalidVorbisComment }
        return FlacPicture(
            pictureType: type,
            mimeType: String(data: mimeBytes, encoding: .ascii) ?? "",
            description: String(data: descBytes, encoding: .utf8) ?? "",
            width: w, height: h, depth: depth, colors: colors,
            data: img
        )
    }

    func encode() -> Data {
        var out = Data()
        out.append(be32(pictureType))
        let mime = Data(mimeType.utf8)
        out.append(be32(UInt32(mime.count)))
        out.append(mime)
        let desc = Data(description.utf8)
        out.append(be32(UInt32(desc.count)))
        out.append(desc)
        out.append(be32(width))
        out.append(be32(height))
        out.append(be32(depth))
        out.append(be32(colors))
        out.append(be32(UInt32(data.count)))
        out.append(data)
        return out
    }

    private func be32(_ v: UInt32) -> Data {
        var be = v.bigEndian
        return Data(bytes: &be, count: 4)
    }
}

// MARK: - Readers

private struct LittleEndianReader {
    let data: Data
    var pos: Int = 0
    init(_ d: Data) { self.data = d; self.pos = d.startIndex }

    mutating func read(_ n: Int) -> Data? {
        guard pos + n <= data.endIndex else { return nil }
        let slice = data.subdata(in: pos..<(pos + n))
        pos += n
        return slice
    }
    mutating func readU32() -> UInt32? {
        guard let b = read(4) else { return nil }
        return b.withUnsafeBytes { $0.load(as: UInt32.self) }.littleEndian
    }
}

private struct BigEndianReader {
    let data: Data
    var pos: Int = 0
    init(_ d: Data) { self.data = d; self.pos = d.startIndex }

    mutating func read(_ n: Int) -> Data? {
        guard pos + n <= data.endIndex else { return nil }
        let slice = data.subdata(in: pos..<(pos + n))
        pos += n
        return slice
    }
    mutating func readU32() -> UInt32? {
        guard let b = read(4) else { return nil }
        let v = b.withUnsafeBytes { $0.load(as: UInt32.self) }
        return UInt32(bigEndian: v)
    }
}
