import Foundation

/// Native Matroska (MKV / MKA / WebM) tag reader & writer.
///
/// Matroska is built on EBML — variable-length element IDs and sizes nested
/// in a tree. The two metadata-bearing elements live as direct children of
/// `Segment`:
///   * `Tags`        — one or more `Tag` elements, each with `Targets` and
///                     a list of `SimpleTag(TagName, TagString)` entries.
///   * `Attachments` — `AttachedFile`(FileName, FileMimeType, FileData,
///                     FileUID) entries; we use the first image one as cover.
///
/// Writing strategy: rather than recompute every parent size after editing,
/// we rewrite the file with the `Segment` declared as **unknown-length**
/// (VINT 0xFF). All original Segment children except `Tags`, `Attachments`
/// and `SeekHead` are kept verbatim; the new `Tags` and `Attachments` are
/// appended at the end. `SeekHead` is dropped — Matroska spec allows this
/// (players linear-scan when SeekHead is absent), avoiding stale offsets.
enum MatroskaError: Error, LocalizedError {
    case notMatroska
    case truncated
    var errorDescription: String? {
        switch self {
        case .notMatroska: return "File is not a valid Matroska/EBML container"
        case .truncated:   return "Matroska file is truncated"
        }
    }
}

struct MatroskaFile {

    let url: URL
    /// Decoded tag entries (Vorbis-style keys).
    let entries: [(key: String, value: String)]
    /// First image attachment, if any.
    let cover: (data: Data, mime: String)?

    // MARK: - Read

    static func read(_ url: URL) throws -> MatroskaFile {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count >= 4,
              data[0] == 0x1A, data[1] == 0x45, data[2] == 0xDF, data[3] == 0xA3
        else { throw MatroskaError.notMatroska }

        // Find Segment.
        var p = 0
        var segmentBodyStart = -1
        var segmentBodyEnd = data.count
        while p < data.count {
            guard let (id, idLen) = EBML.readID(data, at: p) else { break }
            guard let (size, sizeLen, isUnknown) = EBML.readSize(data, at: p + idLen) else { break }
            let bodyStart = p + idLen + sizeLen
            let bodyEnd = isUnknown ? data.count : (bodyStart + Int(size))
            if id == EBML.IDs.segment {
                segmentBodyStart = bodyStart
                segmentBodyEnd = min(bodyEnd, data.count)
                break
            }
            p = bodyEnd
        }
        guard segmentBodyStart > 0 else { throw MatroskaError.notMatroska }

        // Walk Segment children, decoding Tags/Attachments.
        var entries: [(String, String)] = []
        var cover: (Data, String)?
        var q = segmentBodyStart
        while q < segmentBodyEnd {
            guard let (id, idLen) = EBML.readID(data, at: q) else { break }
            guard let (size, sizeLen, _) = EBML.readSize(data, at: q + idLen) else { break }
            let bodyStart = q + idLen + sizeLen
            let bodyEnd = min(bodyStart + Int(size), segmentBodyEnd)
            switch id {
            case EBML.IDs.tags:
                entries.append(contentsOf: decodeTags(data, start: bodyStart, end: bodyEnd))
            case EBML.IDs.attachments:
                if cover == nil {
                    cover = decodeAttachmentsForCover(data, start: bodyStart, end: bodyEnd)
                }
            default:
                break
            }
            q = bodyEnd
        }
        return MatroskaFile(url: url, entries: entries, cover: cover)
    }

    private static func decodeTags(_ data: Data, start: Int, end: Int) -> [(String, String)] {
        var out: [(String, String)] = []
        var p = start
        while p < end {
            guard let (id, idLen) = EBML.readID(data, at: p),
                  let (size, sizeLen, _) = EBML.readSize(data, at: p + idLen)
            else { break }
            let bodyStart = p + idLen + sizeLen
            let bodyEnd = min(bodyStart + Int(size), end)
            if id == EBML.IDs.tag {
                // Within a Tag, walk children: collect SimpleTag entries.
                var q = bodyStart
                while q < bodyEnd {
                    guard let (cid, cidLen) = EBML.readID(data, at: q),
                          let (csize, csizeLen, _) = EBML.readSize(data, at: q + cidLen)
                    else { break }
                    let cBody = q + cidLen + csizeLen
                    let cEnd = min(cBody + Int(csize), bodyEnd)
                    if cid == EBML.IDs.simpleTag, let (n, v) = decodeSimpleTag(data, start: cBody, end: cEnd) {
                        out.append((mapTagNameToVorbis(n), v))
                    }
                    q = cEnd
                }
            }
            p = bodyEnd
        }
        return out
    }

    private static func decodeSimpleTag(_ data: Data, start: Int, end: Int) -> (String, String)? {
        var name: String?
        var value: String?
        var p = start
        while p < end {
            guard let (id, idLen) = EBML.readID(data, at: p),
                  let (size, sizeLen, _) = EBML.readSize(data, at: p + idLen)
            else { break }
            let bodyStart = p + idLen + sizeLen
            let bodyEnd = min(bodyStart + Int(size), end)
            let payload = data.subdata(in: bodyStart..<bodyEnd)
            switch id {
            case EBML.IDs.tagName:    name  = String(data: payload, encoding: .utf8)
            case EBML.IDs.tagString:  value = String(data: payload, encoding: .utf8)
            default: break
            }
            p = bodyEnd
        }
        if let n = name, let v = value { return (n, v) }
        return nil
    }

    private static func decodeAttachmentsForCover(_ data: Data, start: Int, end: Int) -> (Data, String)? {
        var p = start
        var bestNonImage: (Data, String)?
        while p < end {
            guard let (id, idLen) = EBML.readID(data, at: p),
                  let (size, sizeLen, _) = EBML.readSize(data, at: p + idLen)
            else { break }
            let bodyStart = p + idLen + sizeLen
            let bodyEnd = min(bodyStart + Int(size), end)
            if id == EBML.IDs.attachedFile {
                var mime: String?
                var fileData: Data?
                var q = bodyStart
                while q < bodyEnd {
                    guard let (cid, cidLen) = EBML.readID(data, at: q),
                          let (csize, csizeLen, _) = EBML.readSize(data, at: q + cidLen)
                    else { break }
                    let cBody = q + cidLen + csizeLen
                    let cEnd = min(cBody + Int(csize), bodyEnd)
                    let payload = data.subdata(in: cBody..<cEnd)
                    switch cid {
                    case EBML.IDs.fileMimeType: mime = String(data: payload, encoding: .ascii)
                    case EBML.IDs.fileData:     fileData = payload
                    default: break
                    }
                    q = cEnd
                }
                if let m = mime, let d = fileData {
                    if m.hasPrefix("image/") { return (d, m) }
                    if bestNonImage == nil { bestNonImage = (d, m) }
                }
            }
            p = bodyEnd
        }
        return bestNonImage
    }

    // MARK: - Write

    static func write(url: URL,
                      entries: [(key: String, value: String)],
                      cover: (data: Data, mime: String)?) throws {
        let original = try Data(contentsOf: url, options: .mappedIfSafe)
        guard original.count >= 4,
              original[0] == 0x1A, original[1] == 0x45,
              original[2] == 0xDF, original[3] == 0xA3
        else { throw MatroskaError.notMatroska }

        // Locate EBML header and Segment.
        var p = 0
        var ebmlHeaderEnd = 0
        var segmentIDStart = -1
        var segmentBodyStart = -1
        var segmentBodyEnd = original.count
        while p < original.count {
            guard let (id, idLen) = EBML.readID(original, at: p),
                  let (size, sizeLen, isUnknown) = EBML.readSize(original, at: p + idLen)
            else { break }
            let bodyStart = p + idLen + sizeLen
            let bodyEnd = isUnknown ? original.count : min(bodyStart + Int(size), original.count)
            if id == EBML.IDs.ebmlHeader {
                ebmlHeaderEnd = bodyEnd
            } else if id == EBML.IDs.segment {
                segmentIDStart = p
                segmentBodyStart = bodyStart
                segmentBodyEnd = bodyEnd
                break
            }
            p = bodyEnd
        }
        guard segmentIDStart >= 0 else { throw MatroskaError.notMatroska }

        // Collect Segment children, dropping SeekHead/Tags/Attachments. We keep
        // the raw bytes of every other child to preserve them verbatim.
        var keptChildrenBytes = Data()
        var q = segmentBodyStart
        while q < segmentBodyEnd {
            guard let (cid, cidLen) = EBML.readID(original, at: q),
                  let (csize, csizeLen, _) = EBML.readSize(original, at: q + cidLen)
            else { break }
            let bodyStart = q + cidLen + csizeLen
            let bodyEnd = min(bodyStart + Int(csize), segmentBodyEnd)
            switch cid {
            case EBML.IDs.seekHead, EBML.IDs.tags, EBML.IDs.attachments:
                break // drop
            default:
                keptChildrenBytes.append(original.subdata(in: q..<bodyEnd))
            }
            q = bodyEnd
        }

        // Build new Tags + Attachments and assemble a Segment with unknown
        // length (one VINT byte = 0xFF) so we never need to compute its size.
        var newSegmentBody = Data()
        newSegmentBody.append(keptChildrenBytes)
        newSegmentBody.append(buildTagsElement(entries: entries))
        if let cover {
            newSegmentBody.append(buildAttachmentsElement(cover: cover))
        }

        var out = Data()
        out.append(original.subdata(in: 0..<ebmlHeaderEnd))   // EBML header verbatim
        out.append(EBML.IDs.segmentBytes)                     // Segment ID
        out.append(0xFF)                                       // unknown-size VINT
        out.append(newSegmentBody)

        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        try out.write(to: tmp, options: .atomic)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }

    // MARK: - Element builders

    /// Build a `Tags` element. We emit one `Tag` with TargetTypeValue=50
    /// (Album/Movie/etc.) containing every entry as a SimpleTag — this is
    /// the level that Matroska players typically look at for file-wide
    /// metadata. Track/disc numbers piggy-back as PART_NUMBER / TOTAL_PARTS
    /// per the standard tag table.
    private static func buildTagsElement(entries: [(key: String, value: String)]) -> Data {
        var simpleTags = Data()
        for (rawKey, value) in entries where !value.isEmpty {
            let mkvName = mapVorbisToTagName(rawKey.uppercased())
            simpleTags.append(buildSimpleTag(name: mkvName, value: value))
        }

        var targets = Data()
        targets.append(EBML.element(id: EBML.IDs.targetTypeValue,
                                    payload: EBML.encodeUInt(50)))

        var tagBody = Data()
        tagBody.append(EBML.element(id: EBML.IDs.targets, payload: targets))
        tagBody.append(simpleTags)

        let tagElem = EBML.element(id: EBML.IDs.tag, payload: tagBody)
        return EBML.element(id: EBML.IDs.tags, payload: tagElem)
    }

    private static func buildSimpleTag(name: String, value: String) -> Data {
        var body = Data()
        body.append(EBML.element(id: EBML.IDs.tagName,    payload: Data(name.utf8)))
        body.append(EBML.element(id: EBML.IDs.tagString,  payload: Data(value.utf8)))
        return EBML.element(id: EBML.IDs.simpleTag, payload: body)
    }

    private static func buildAttachmentsElement(cover: (data: Data, mime: String)) -> Data {
        var fileBody = Data()
        let fileName = cover.mime.contains("png") ? "cover.png" : "cover.jpg"
        fileBody.append(EBML.element(id: EBML.IDs.fileDescription,
                                     payload: Data("Cover (front)".utf8)))
        fileBody.append(EBML.element(id: EBML.IDs.fileName,
                                     payload: Data(fileName.utf8)))
        fileBody.append(EBML.element(id: EBML.IDs.fileMimeType,
                                     payload: Data(cover.mime.utf8)))
        // Stable UID derived from data hash (any non-zero unsigned int works).
        var uid: UInt64 = 0xDEADBEEF
        for (i, b) in cover.data.prefix(64).enumerated() {
            uid &+= UInt64(b) &* UInt64(i + 1)
        }
        if uid == 0 { uid = 1 }
        fileBody.append(EBML.element(id: EBML.IDs.fileUID,
                                     payload: EBML.encodeUInt(uid)))
        fileBody.append(EBML.element(id: EBML.IDs.fileData,
                                     payload: cover.data))
        let attachedFile = EBML.element(id: EBML.IDs.attachedFile, payload: fileBody)
        return EBML.element(id: EBML.IDs.attachments, payload: attachedFile)
    }

    // MARK: - Tag name mapping

    /// Map Matroska standard tag names → our Vorbis-style internal names.
    private static func mapTagNameToVorbis(_ name: String) -> String {
        switch name.uppercased() {
        case "TITLE":          return "TITLE"
        case "ARTIST":         return "ARTIST"
        case "ALBUM":          return "ALBUM"
        case "ALBUM_ARTIST":   return "ALBUMARTIST"
        case "DATE_RELEASED",
             "DATE_RECORDED",
             "DATE":           return "DATE"
        case "GENRE":          return "GENRE"
        case "COMPOSER":       return "COMPOSER"
        case "COMMENT":        return "COMMENT"
        case "PART_NUMBER":    return "TRACKNUMBER"
        case "TOTAL_PARTS":    return "TRACKTOTAL"
        case "DISC_NUMBER",
             "DISCNUMBER":     return "DISCNUMBER"
        case "TOTAL_DISCS",
             "DISCTOTAL":      return "DISCTOTAL"
        default:               return name.uppercased()
        }
    }

    private static func mapVorbisToTagName(_ key: String) -> String {
        switch key {
        case "TITLE":        return "TITLE"
        case "ARTIST":       return "ARTIST"
        case "ALBUM":        return "ALBUM"
        case "ALBUMARTIST":  return "ALBUM_ARTIST"
        case "DATE":         return "DATE_RELEASED"
        case "GENRE":        return "GENRE"
        case "COMPOSER":     return "COMPOSER"
        case "COMMENT":      return "COMMENT"
        case "TRACKNUMBER":  return "PART_NUMBER"
        case "TRACKTOTAL":   return "TOTAL_PARTS"
        case "DISCNUMBER":   return "DISC_NUMBER"
        case "DISCTOTAL":    return "TOTAL_DISCS"
        default:             return key
        }
    }
}

// MARK: - EBML primitives (file-private)

fileprivate enum EBML {

    enum IDs {
        // Top-level
        static let ebmlHeader: UInt64    = 0x1A45DFA3
        static let segment: UInt64       = 0x18538067
        static let segmentBytes = Data([0x18, 0x53, 0x80, 0x67])
        // Segment children we care about
        static let seekHead: UInt64      = 0x114D9B74
        static let tags: UInt64          = 0x1254C367
        static let attachments: UInt64   = 0x1941A469
        // Tag children
        static let tag: UInt64           = 0x7373
        static let targets: UInt64       = 0x63C0
        static let targetTypeValue: UInt64 = 0x68CA
        static let simpleTag: UInt64     = 0x67C8
        static let tagName: UInt64       = 0x45A3
        static let tagString: UInt64     = 0x4487
        // Attachment children
        static let attachedFile: UInt64    = 0x61A7
        static let fileDescription: UInt64 = 0x467E
        static let fileName: UInt64        = 0x466E
        static let fileMimeType: UInt64    = 0x4660
        static let fileData: UInt64        = 0x465C
        static let fileUID: UInt64         = 0x46AE
    }

    /// Read an EBML element ID at `at` (preserving its leading-1 marker).
    /// Returns the ID interpreted as a UInt64 and the byte length consumed.
    static func readID(_ data: Data, at offset: Int) -> (UInt64, Int)? {
        guard offset < data.count else { return nil }
        let first = data[offset]
        guard first != 0 else { return nil }
        // Find the position of the leading 1 → length 1..4.
        var len = 0
        for n in 1...4 {
            if first & UInt8(0x80 >> (n - 1)) != 0 { len = n; break }
        }
        guard len > 0, offset + len <= data.count else { return nil }
        var v: UInt64 = 0
        for i in 0..<len {
            v = (v << 8) | UInt64(data[offset + i])
        }
        return (v, len)
    }

    /// Read an EBML VINT-size at `at`. Strips the marker bit. Returns
    /// (value, byteLength, isUnknown).
    static func readSize(_ data: Data, at offset: Int) -> (UInt64, Int, Bool)? {
        guard offset < data.count else { return nil }
        let first = data[offset]
        guard first != 0 else { return nil }
        var len = 0
        for n in 1...8 {
            if first & UInt8(0x80 >> (n - 1)) != 0 { len = n; break }
        }
        guard len > 0, offset + len <= data.count else { return nil }
        // Strip marker bit from first byte.
        let mask: UInt8 = UInt8((1 << (8 - len)) - 1)
        var v: UInt64 = UInt64(first & mask)
        for i in 1..<len {
            v = (v << 8) | UInt64(data[offset + i])
        }
        // Detect "unknown size": all data bits set.
        let maxVal: UInt64 = (UInt64(1) << UInt64(7 * len)) - 1
        return (v, len, v == maxVal)
    }

    /// Encode an unsigned integer as a VINT-encoded SIZE (with marker bit).
    static func encodeSize(_ value: UInt64) -> Data {
        for n in 1...8 {
            let max: UInt64 = (UInt64(1) << UInt64(7 * n)) - 1
            if value < max {     // strict-less so we never collide with "unknown"
                var bytes = [UInt8](repeating: 0, count: n)
                var v = value
                for i in stride(from: n - 1, through: 1, by: -1) {
                    bytes[i] = UInt8(v & 0xFF); v >>= 8
                }
                bytes[0] = UInt8(v) | UInt8(0x80 >> (n - 1))
                return Data(bytes)
            }
        }
        // Fallback (shouldn't happen for our payload sizes).
        return Data([0xFF])
    }

    /// Encode an unsigned integer payload (variable 1..8 bytes, big-endian).
    static func encodeUInt(_ value: UInt64) -> Data {
        if value == 0 { return Data([0]) }
        var v = value
        var bytes: [UInt8] = []
        while v > 0 { bytes.insert(UInt8(v & 0xFF), at: 0); v >>= 8 }
        return Data(bytes)
    }

    /// Encode element ID `id` (4-byte form preserving its marker bit) as bytes.
    static func encodeID(_ id: UInt64) -> Data {
        // Determine ID byte length by inspecting the high-bit of the topmost byte.
        // IDs in our table are 2 or 4 bytes.
        var bytes: [UInt8] = []
        var v = id
        while v > 0 { bytes.insert(UInt8(v & 0xFF), at: 0); v >>= 8 }
        return Data(bytes)
    }

    /// Build an EBML element: ID + VINT(size) + payload.
    static func element(id: UInt64, payload: Data) -> Data {
        var d = Data()
        d.append(encodeID(id))
        d.append(encodeSize(UInt64(payload.count)))
        d.append(payload)
        return d
    }
}
