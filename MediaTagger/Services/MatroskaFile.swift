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

    /// Read tags + cover from a Matroska file.
    ///
    /// We deliberately avoid `Data(contentsOf: .mappedIfSafe)` here:
    /// for multi-GB MKVs that call frequently falls back to a full file
    /// copy into memory (sandboxed paths, network volumes, large files all
    /// defeat mmap), which can take minutes. Instead we open a `FileHandle`
    /// and read only the small ranges we actually need:
    ///   1. A small head buffer to locate EBML header + Segment header + SeekHead.
    ///   2. For each interesting element (Tags, Attachments) the SeekHead
    ///      points to, just enough bytes to cover the element body.
    /// Total bytes read for a typical 5 GB MKV: a few hundred KB.
    static func read(_ url: URL) throws -> MatroskaFile {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let fileSize = (try? handle.seekToEnd()) ?? 0
        try handle.seek(toOffset: 0)

        // 1. Read the head: enough for EBML header + Segment header + SeekHead.
        //    SeekHead is normally <2 KB; 64 KB gives plenty of headroom.
        let headLen = min(UInt64(64 * 1024), fileSize)
        let head = handle.readData(ofLength: Int(headLen))
        guard head.count >= 4,
              head[0] == 0x1A, head[1] == 0x45, head[2] == 0xDF, head[3] == 0xA3
        else { throw MatroskaError.notMatroska }

        // 2. Locate Segment in the head buffer.
        var p = 0
        var segmentBodyAbs: UInt64 = 0
        var segmentBodyEndAbs: UInt64 = fileSize
        while p < head.count {
            guard let (id, idLen) = EBML.readID(head, at: p),
                  let (size, sizeLen, isUnknown) = EBML.readSize(head, at: p + idLen)
            else { break }
            let bodyStartAbs = UInt64(p + idLen + sizeLen)
            if id == EBML.IDs.segment {
                segmentBodyAbs = bodyStartAbs
                segmentBodyEndAbs = isUnknown ? fileSize
                    : min(bodyStartAbs + size, fileSize)
                break
            }
            p = isUnknown ? head.count : Int(bodyStartAbs + size)
        }
        guard segmentBodyAbs > 0 else { throw MatroskaError.notMatroska }

        var entries: [(String, String)] = []
        var cover: (Data, String)?

        // 3. Try the SeekHead fast path. We slice the head buffer to give the
        //    existing decoders a Data + offset view starting at the Segment body.
        let segmentRelOffset = Int(segmentBodyAbs)
        if segmentRelOffset < head.count {
            let segBodyEndInHead = min(Int(segmentBodyEndAbs), head.count)
            let seekTargets = readSeekHeadTargets(
                head,
                segmentBodyStart: segmentRelOffset,
                segmentBodyEnd: segBodyEndInHead
            )
            if !seekTargets.isEmpty {
                if let off = seekTargets[EBML.IDs.tags] {
                    if let body = try readElementBody(
                        handle: handle, fileSize: fileSize,
                        absOffset: segmentBodyAbs + off,
                        expectedID: EBML.IDs.tags
                    ) {
                        entries.append(contentsOf: decodeTags(body, start: 0, end: body.count))
                    }
                }
                if let off = seekTargets[EBML.IDs.attachments] {
                    if let body = try readElementBody(
                        handle: handle, fileSize: fileSize,
                        absOffset: segmentBodyAbs + off,
                        expectedID: EBML.IDs.attachments
                    ) {
                        cover = decodeAttachmentsForCover(body, start: 0, end: body.count)
                    }
                }
                return MatroskaFile(url: url, entries: entries, cover: cover)
            }
        }

        // 4. Fallback: stream Segment children directly from the FileHandle,
        //    stopping at the first Cluster. Tags/Attachments are required to
        //    appear before the first Cluster when no SeekHead is present.
        var abs = segmentBodyAbs
        while abs < segmentBodyEndAbs {
            try handle.seek(toOffset: abs)
            let hdr = handle.readData(ofLength: 16)
            guard let (id, idLen) = EBML.readID(hdr, at: 0),
                  let (size, sizeLen, _) = EBML.readSize(hdr, at: idLen)
            else { break }
            let bodyAbs = abs + UInt64(idLen + sizeLen)
            let bodyEndAbs = min(bodyAbs + size, segmentBodyEndAbs)
            switch id {
            case EBML.IDs.tags:
                try handle.seek(toOffset: bodyAbs)
                let body = handle.readData(ofLength: Int(bodyEndAbs - bodyAbs))
                entries.append(contentsOf: decodeTags(body, start: 0, end: body.count))
            case EBML.IDs.attachments:
                try handle.seek(toOffset: bodyAbs)
                let body = handle.readData(ofLength: Int(bodyEndAbs - bodyAbs))
                if cover == nil {
                    cover = decodeAttachmentsForCover(body, start: 0, end: body.count)
                }
            case EBML.IDs.cluster:
                return MatroskaFile(url: url, entries: entries, cover: cover)
            default:
                break
            }
            abs = bodyEndAbs
        }
        return MatroskaFile(url: url, entries: entries, cover: cover)
    }

    /// Read element header at absolute offset `absOffset`, verify its ID,
    /// then read and return its body bytes. Returns nil if the header does
    /// not parse or the ID does not match.
    private static func readElementBody(handle: FileHandle,
                                        fileSize: UInt64,
                                        absOffset: UInt64,
                                        expectedID: UInt64) throws -> Data? {
        guard absOffset + 16 <= fileSize else { return nil }
        try handle.seek(toOffset: absOffset)
        let hdr = handle.readData(ofLength: 16)
        guard let (id, idLen) = EBML.readID(hdr, at: 0),
              id == expectedID,
              let (size, sizeLen, _) = EBML.readSize(hdr, at: idLen)
        else { return nil }
        let bodyAbs = absOffset + UInt64(idLen + sizeLen)
        guard bodyAbs <= fileSize else { return nil }
        let bodyLen = Int(min(size, fileSize - bodyAbs))
        try handle.seek(toOffset: bodyAbs)
        return handle.readData(ofLength: bodyLen)
    }

    /// Read SeekHead at the start of the Segment body and return a map of
    /// `SeekID -> SeekPosition` (offsets relative to the start of the
    /// Segment body). Returns empty if no SeekHead is found in the first
    /// few children.
    private static func readSeekHeadTargets(_ data: Data,
                                            segmentBodyStart: Int,
                                            segmentBodyEnd: Int) -> [UInt64: UInt64] {
        var out: [UInt64: UInt64] = [:]
        var p = segmentBodyStart
        // Look at up to the first 4 Segment children (a SeekHead is almost
        // always the first one, occasionally the second).
        for _ in 0..<4 {
            guard p < segmentBodyEnd,
                  let (id, idLen) = EBML.readID(data, at: p),
                  let (size, sizeLen, _) = EBML.readSize(data, at: p + idLen)
            else { return out }
            let bodyStart = p + idLen + sizeLen
            let bodyEnd = min(bodyStart + Int(size), segmentBodyEnd)
            if id == EBML.IDs.seekHead {
                var q = bodyStart
                while q < bodyEnd {
                    guard let (eid, eidLen) = EBML.readID(data, at: q),
                          let (esize, esizeLen, _) = EBML.readSize(data, at: q + eidLen)
                    else { break }
                    let eBody = q + eidLen + esizeLen
                    let eEnd = min(eBody + Int(esize), bodyEnd)
                    if eid == EBML.IDs.seek {
                        var seekID: UInt64?
                        var seekPos: UInt64?
                        var r = eBody
                        while r < eEnd {
                            guard let (cid, cidLen) = EBML.readID(data, at: r),
                                  let (csize, csizeLen, _) = EBML.readSize(data, at: r + cidLen)
                            else { break }
                            let cBody = r + cidLen + csizeLen
                            let cEnd = min(cBody + Int(csize), eEnd)
                            let payload = data.subdata(in: cBody..<cEnd)
                            if cid == EBML.IDs.seekID {
                                // SeekID payload is itself a VINT-encoded ID.
                                var v: UInt64 = 0
                                for b in payload { v = (v << 8) | UInt64(b) }
                                seekID = v
                            } else if cid == EBML.IDs.seekPosition {
                                var v: UInt64 = 0
                                for b in payload { v = (v << 8) | UInt64(b) }
                                seekPos = v
                            }
                            r = cEnd
                        }
                        if let sid = seekID, let sp = seekPos { out[sid] = sp }
                    }
                    q = eEnd
                }
                return out
            }
            p = bodyEnd
        }
        return out
    }

    /// Read an EBML element header at `offset` and verify it matches
    /// `expectedID`. Returns the body's start and end byte offsets.
    private static func elementBody(_ data: Data, at offset: Int,
                                    expectedID: UInt64,
                                    parentEnd: Int) -> (start: Int, end: Int)? {
        guard offset >= 0, offset < parentEnd,
              let (id, idLen) = EBML.readID(data, at: offset),
              id == expectedID,
              let (size, sizeLen, _) = EBML.readSize(data, at: offset + idLen)
        else { return nil }
        let start = offset + idLen + sizeLen
        let end = min(start + Int(size), parentEnd)
        return (start, end)
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
        static let seek: UInt64          = 0x4DBB
        static let seekID: UInt64        = 0x53AB
        static let seekPosition: UInt64  = 0x53AC
        static let cluster: UInt64       = 0x1F43B675
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
