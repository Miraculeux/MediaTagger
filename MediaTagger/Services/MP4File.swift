import Foundation

/// Native MP4 / M4A (ISO BMFF) parser + writer focused on iTunes-style metadata
/// stored at `moov/udta/meta/ilst`. Supports read and write of the standard text
/// atoms (©nam/©ART/aART/©alb/©day/©gen/©wrt/©cmt), `trkn`, `disk`, and `covr`,
/// plus freeform `----:com.apple.iTunes:KEY` atoms for unknown keys.
///
/// Writing strategy: parse all top-level atoms, rebuild `moov` with modified
/// metadata, then patch every `stco` / `co64` chunk-offset table by the size
/// delta if `mdat` ends up shifted. Top-level atom order is preserved.
struct MP4File {

    // MARK: - Parsed model

    /// One iTunes-style metadata entry as it lives under `ilst`.
    struct Entry {
        var key: String          // e.g. "TITLE", "ARTIST", or freeform "MOOD"
        var value: String        // text value (for cover art, see `cover`)
    }

    struct Cover {
        var data: Data
        var mime: String         // "image/jpeg" or "image/png"
    }

    let url: URL
    fileprivate let topAtoms: [Atom]
    fileprivate let fileSize: UInt64

    // MARK: - Read

    static func read(_ url: URL) throws -> MP4File {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { UInt64($0) } ?? 0
        let atoms = try AtomParser.parseSiblings(handle: handle, start: 0, end: size)
        return MP4File(url: url, topAtoms: atoms, fileSize: size)
    }

    /// Decode metadata entries + cover from `moov/udta/meta/ilst`.
    func decoded() -> (entries: [Entry], cover: Cover?) {
        guard
            let moov = topAtoms.first(where: { $0.type == "moov" }),
            let udta = moov.childContainer(type: "udta"),
            let meta = udta.childMeta(),
            let ilst = meta.childContainer(type: "ilst")
        else { return ([], nil) }

        var out: [Entry] = []
        var cover: Cover?

        for tag in ilst.children {
            // Each tag atom contains one or more `data` (or `mean`/`name`/`data`
            // for freeform `----`) children.
            if tag.type == "----" {
                // Freeform: mean / name / data
                var name: String?
                var dataBytes: Data?
                var dataType: UInt32 = 0
                for c in tag.children {
                    let payload = c.readPayload(from: url)
                    if c.type == "name" && payload.count >= 4 {
                        name = String(data: payload.dropFirst(4), encoding: .utf8)
                    } else if c.type == "data" && payload.count >= 8 {
                        dataType = payload.subdata(in: 0..<4).beUInt32 & 0x00FFFFFF
                        dataBytes = payload.subdata(in: 8..<payload.count)
                    }
                }
                if let n = name, let d = dataBytes,
                   let s = (dataType == 1) ? String(data: d, encoding: .utf8) : nil {
                    out.append(Entry(key: n.uppercased(), value: s))
                }
                continue
            }

            guard let dataAtom = tag.children.first(where: { $0.type == "data" }) else { continue }
            let payload = dataAtom.readPayload(from: url)
            guard payload.count >= 8 else { continue }
            let typeIndicator = payload.subdata(in: 0..<4).beUInt32 & 0x00FFFFFF
            let value = payload.subdata(in: 8..<payload.count)

            switch tag.type {
            case "covr":
                if !value.isEmpty {
                    let mime = (typeIndicator == 14) ? "image/png" : "image/jpeg"
                    cover = Cover(data: value, mime: mime)
                }
            case "trkn":
                if value.count >= 6 {
                    let n = UInt16(value[value.startIndex.advanced(by: 2)]) << 8 |
                            UInt16(value[value.startIndex.advanced(by: 3)])
                    let t = UInt16(value[value.startIndex.advanced(by: 4)]) << 8 |
                            UInt16(value[value.startIndex.advanced(by: 5)])
                    if n > 0 { out.append(.init(key: "TRACKNUMBER", value: "\(n)")) }
                    if t > 0 { out.append(.init(key: "TRACKTOTAL",  value: "\(t)")) }
                }
            case "disk":
                if value.count >= 6 {
                    let n = UInt16(value[value.startIndex.advanced(by: 2)]) << 8 |
                            UInt16(value[value.startIndex.advanced(by: 3)])
                    let t = UInt16(value[value.startIndex.advanced(by: 4)]) << 8 |
                            UInt16(value[value.startIndex.advanced(by: 5)])
                    if n > 0 { out.append(.init(key: "DISCNUMBER", value: "\(n)")) }
                    if t > 0 { out.append(.init(key: "DISCTOTAL",  value: "\(t)")) }
                }
            case "gnre":
                // ID3v1-style 1-based genre index. Rare in modern files.
                if value.count >= 2 {
                    let idx = Int(value[value.startIndex.advanced(by: 1)])
                    if idx > 0, idx - 1 < Self.id3v1Genres.count {
                        out.append(.init(key: "GENRE", value: Self.id3v1Genres[idx - 1]))
                    }
                }
            default:
                if let key = Self.atomToKey[tag.type],
                   let s = String(data: value, encoding: .utf8) {
                    out.append(.init(key: key, value: s))
                }
            }
        }
        return (out, cover)
    }

    // MARK: - Write

    /// Replace metadata atoms inside `moov/udta/meta/ilst`, rewrite the file
    /// atomically, and patch `stco` / `co64` offsets to keep media playback
    /// working after the `moov` size changes.
    static func write(url: URL,
                      entries: [(key: String, value: String)],
                      cover: Cover?) throws {
        let file = try MP4File.read(url)
        try file.writeReplacingMetadata(entries: entries, cover: cover)
    }

    fileprivate func writeReplacingMetadata(entries: [(key: String, value: String)],
                                            cover: Cover?) throws {
        // Memory-map the input so very large containers (multi-GB MP4 video)
        // don't cause a full-file copy into the resident set just to read the
        // moov bytes. The kernel pages content in on demand; subdata() and
        // the rebuild path then allocate only what they need.
        let original = try Data(contentsOf: url, options: .mappedIfSafe)

        guard let moovIdx = topAtoms.firstIndex(where: { $0.type == "moov" }) else {
            throw NSError(domain: "MediaTagger.MP4", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No moov atom"])
        }
        let moov = topAtoms[moovIdx]
        let oldMoovBytes = original.subdata(in: Int(moov.start)..<Int(moov.end))

        let newIlst = Self.buildIlst(entries: entries, cover: cover)
        let newMoov = Self.rebuildMoov(originalMoov: oldMoovBytes, newIlst: newIlst)

        let delta = Int64(newMoov.count) - Int64(oldMoovBytes.count)

        // Determine if any top-level atom positioned AFTER moov holds media
        // pointed to by stco/co64 (typically `mdat`). If so, patch offsets.
        let mdatShifts = topAtoms.contains { $0.start > moov.start && $0.type == "mdat" }
        let patchedMoov: Data
        if mdatShifts && delta != 0 {
            patchedMoov = Self.patchChunkOffsets(in: newMoov, delta: delta)
        } else {
            patchedMoov = newMoov
        }

        // Reassemble: top-level atoms in order, swapping moov for patchedMoov.
        var out = Data()
        out.reserveCapacity(original.count + max(0, Int(delta)))
        for (i, atom) in topAtoms.enumerated() {
            if i == moovIdx {
                out.append(patchedMoov)
            } else {
                out.append(original.subdata(in: Int(atom.start)..<Int(atom.end)))
            }
        }

        // Atomic replace.
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        try out.write(to: tmp, options: .atomic)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }

    // MARK: - Building moov / ilst

    /// Build the new `ilst` atom payload (without its 8-byte header).
    private static func buildIlst(entries: [(key: String, value: String)],
                                  cover: Cover?) -> Data {
        var ilstBody = Data()

        // Group track/disc components so we emit a single trkn / disk atom.
        var dict: [String: String] = [:]
        var freeform: [(String, String)] = []
        var standardOrder: [String] = []
        for e in entries {
            let k = e.key.uppercased()
            if dict[k] == nil { standardOrder.append(k) }
            dict[k] = e.value
        }

        // Standard text atoms.
        for k in standardOrder {
            switch k {
            case "TRACKNUMBER", "TRACKTOTAL", "DISCNUMBER", "DISCTOTAL":
                continue // handled below
            default:
                if let atomType = keyToAtom[k] {
                    ilstBody.append(makeTextTag(type: atomType, value: dict[k] ?? ""))
                } else {
                    freeform.append((k, dict[k] ?? ""))
                }
            }
        }

        // trkn / disk
        let tn = UInt16(dict["TRACKNUMBER"] ?? "") ?? 0
        let tt = UInt16(dict["TRACKTOTAL"] ?? "") ?? 0
        if tn > 0 || tt > 0 {
            ilstBody.append(makeTrackTag(type: "trkn", n: tn, t: tt, padding8: true))
        }
        let dn = UInt16(dict["DISCNUMBER"] ?? "") ?? 0
        let dt = UInt16(dict["DISCTOTAL"] ?? "") ?? 0
        if dn > 0 || dt > 0 {
            ilstBody.append(makeTrackTag(type: "disk", n: dn, t: dt, padding8: false))
        }

        // covr
        if let cover {
            ilstBody.append(makeCoverTag(cover))
        }

        // Freeform (----:com.apple.iTunes:KEY)
        for (k, v) in freeform {
            ilstBody.append(makeFreeformTag(key: k, value: v))
        }

        return makeAtom(type: "ilst", payload: ilstBody)
    }

    /// Reconstruct `moov` by recursing into udta/meta and substituting `ilst`.
    /// Other udta children and any extra meta children (hdlr, etc.) are kept
    /// from the original. If udta or meta is missing, they are created.
    private static func rebuildMoov(originalMoov: Data, newIlst: Data) -> Data {
        // Parse just enough of moov to find udta & meta.
        let moovHeaderSize = 8
        let moovBody = originalMoov.subdata(in: moovHeaderSize..<originalMoov.count)
        let children = AtomParser.parseInMemorySiblings(moovBody)

        var newMoovBody = Data()
        var udtaHandled = false

        for c in children {
            if c.type == "udta" {
                let newUdta = rebuildUdta(originalUdta: c.fullBytes(in: moovBody),
                                          newIlst: newIlst)
                newMoovBody.append(newUdta)
                udtaHandled = true
            } else {
                newMoovBody.append(c.fullBytes(in: moovBody))
            }
        }
        if !udtaHandled {
            // Append a fresh udta containing meta+ilst (and hdlr).
            let newUdta = makeFreshUdta(newIlst: newIlst)
            newMoovBody.append(newUdta)
        }

        return makeAtom(type: "moov", payload: newMoovBody)
    }

    private static func rebuildUdta(originalUdta: Data, newIlst: Data) -> Data {
        let udtaBody = originalUdta.subdata(in: 8..<originalUdta.count)
        let children = AtomParser.parseInMemorySiblings(udtaBody)

        var newUdtaBody = Data()
        var metaHandled = false
        for c in children {
            if c.type == "meta" {
                let newMeta = rebuildMeta(originalMeta: c.fullBytes(in: udtaBody),
                                          newIlst: newIlst)
                newUdtaBody.append(newMeta)
                metaHandled = true
            } else {
                newUdtaBody.append(c.fullBytes(in: udtaBody))
            }
        }
        if !metaHandled {
            newUdtaBody.append(makeFreshMeta(newIlst: newIlst))
        }
        return makeAtom(type: "udta", payload: newUdtaBody)
    }

    private static func rebuildMeta(originalMeta: Data, newIlst: Data) -> Data {
        // meta is a "full atom": 4 bytes version+flags, then children.
        let body = originalMeta.subdata(in: 8..<originalMeta.count)
        let prefix = body.subdata(in: 0..<min(4, body.count))
        let childArea = body.subdata(in: min(4, body.count)..<body.count)
        let children = AtomParser.parseInMemorySiblings(childArea)

        var newBody = Data()
        newBody.append(prefix)
        var ilstHandled = false
        for c in children {
            if c.type == "ilst" {
                newBody.append(newIlst)
                ilstHandled = true
            } else {
                newBody.append(c.fullBytes(in: childArea))
            }
        }
        if !ilstHandled {
            newBody.append(newIlst)
        }
        return makeAtom(type: "meta", payload: newBody)
    }

    private static func makeFreshMeta(newIlst: Data) -> Data {
        var body = Data([0, 0, 0, 0]) // version+flags
        // hdlr atom required by iTunes for meta to be recognized.
        var hdlrPayload = Data()
        hdlrPayload.append(contentsOf: [0, 0, 0, 0])               // version+flags
        hdlrPayload.append(contentsOf: [0, 0, 0, 0])               // predefined
        hdlrPayload.append(Data("mdir".utf8))                      // handler_type
        hdlrPayload.append(Data("appl".utf8))                      // reserved[0]
        hdlrPayload.append(contentsOf: [0, 0, 0, 0])               // reserved[1]
        hdlrPayload.append(contentsOf: [0, 0, 0, 0])               // reserved[2]
        hdlrPayload.append(contentsOf: [0])                        // name (empty)
        body.append(makeAtom(type: "hdlr", payload: hdlrPayload))
        body.append(newIlst)
        return makeAtom(type: "meta", payload: body)
    }

    private static func makeFreshUdta(newIlst: Data) -> Data {
        let meta = makeFreshMeta(newIlst: newIlst)
        return makeAtom(type: "udta", payload: meta)
    }

    // MARK: - Atom builders

    private static func makeAtom(type: String, payload: Data) -> Data {
        var out = Data()
        let total = UInt32(8 + payload.count)
        out.append(beUInt32: total)
        // Atom type 4CCs may contain bytes >= 0x80 (e.g. © = 0xA9 in iTunes
        // tags). UTF-8 would encode © as 2 bytes — ISO-Latin-1 keeps it as 1.
        out.append(type.data(using: .isoLatin1) ?? Data(type.utf8))
        out.append(payload)
        return out
    }

    /// Build a single text-style ilst child: type='\(atomType)', containing one
    /// `data` atom with type indicator 1 (UTF-8).
    private static func makeTextTag(type atomType: String, value: String) -> Data {
        var dataPayload = Data()
        dataPayload.append(beUInt32: 0x0000_0001) // version=0, flags=1 (UTF-8)
        dataPayload.append(beUInt32: 0)           // locale
        dataPayload.append(Data(value.utf8))
        let dataAtom = makeAtom(type: "data", payload: dataPayload)
        return makeAtom(type: atomType, payload: dataAtom)
    }

    private static func makeTrackTag(type: String, n: UInt16, t: UInt16, padding8: Bool) -> Data {
        var dataPayload = Data()
        dataPayload.append(beUInt32: 0)           // version=0, flags=0 (binary)
        dataPayload.append(beUInt32: 0)           // locale
        dataPayload.append(contentsOf: [0, 0])    // reserved
        dataPayload.append(beUInt16: n)
        dataPayload.append(beUInt16: t)
        if padding8 { dataPayload.append(contentsOf: [0, 0]) }
        let dataAtom = makeAtom(type: "data", payload: dataPayload)
        return makeAtom(type: type, payload: dataAtom)
    }

    private static func makeCoverTag(_ cover: Cover) -> Data {
        let typeIndicator: UInt32 = (cover.mime.lowercased().contains("png")) ? 14 : 13
        var dataPayload = Data()
        dataPayload.append(beUInt32: typeIndicator)
        dataPayload.append(beUInt32: 0)
        dataPayload.append(cover.data)
        let dataAtom = makeAtom(type: "data", payload: dataPayload)
        return makeAtom(type: "covr", payload: dataAtom)
    }

    private static func makeFreeformTag(key: String, value: String) -> Data {
        let mean = "com.apple.iTunes"
        var meanPayload = Data()
        meanPayload.append(beUInt32: 0) // version+flags
        meanPayload.append(Data(mean.utf8))

        var namePayload = Data()
        namePayload.append(beUInt32: 0)
        namePayload.append(Data(key.utf8))

        var dataPayload = Data()
        dataPayload.append(beUInt32: 0x0000_0001)
        dataPayload.append(beUInt32: 0)
        dataPayload.append(Data(value.utf8))

        var body = Data()
        body.append(makeAtom(type: "mean", payload: meanPayload))
        body.append(makeAtom(type: "name", payload: namePayload))
        body.append(makeAtom(type: "data", payload: dataPayload))
        return makeAtom(type: "----", payload: body)
    }

    // MARK: - Patch chunk offsets

    /// Walk `moov`'s descendants in-place (in the rebuilt bytes) and add `delta`
    /// to every entry of every `stco` (32-bit) / `co64` (64-bit) chunk-offset
    /// table. Top-level atom order is preserved, so chunk offsets simply shift.
    private static func patchChunkOffsets(in moovData: Data, delta: Int64) -> Data {
        var data = moovData
        // Walk any nested atoms; visit `stco` and `co64` payloads.
        patchAtomTreeInPlace(data: &data, start: 0, end: data.count, delta: delta)
        return data
    }

    private static func patchAtomTreeInPlace(data: inout Data, start: Int, end: Int, delta: Int64) {
        var p = start
        while p + 8 <= end {
            let size = Int(data.subdata(in: p..<p+4).beUInt32)
            guard size >= 8, p + size <= end else { return }
            let type = String(data: data.subdata(in: p+4..<p+8), encoding: .isoLatin1) ?? ""
            let payloadStart = p + 8
            let payloadEnd   = p + size
            switch type {
            case "moov", "trak", "mdia", "minf", "stbl", "edts", "udta":
                patchAtomTreeInPlace(data: &data, start: payloadStart, end: payloadEnd, delta: delta)
            case "stco":
                patchStco32(data: &data, start: payloadStart, end: payloadEnd, delta: delta)
            case "co64":
                patchCo64(data: &data, start: payloadStart, end: payloadEnd, delta: delta)
            default:
                break
            }
            p += size
        }
    }

    private static func patchStco32(data: inout Data, start: Int, end: Int, delta: Int64) {
        // 4 bytes version+flags, 4 bytes entry_count, then N * 4 bytes offsets
        guard start + 8 <= end else { return }
        let count = Int(data.subdata(in: start+4..<start+8).beUInt32)
        var off = start + 8
        for _ in 0..<count {
            guard off + 4 <= end else { return }
            let cur = Int64(data.subdata(in: off..<off+4).beUInt32)
            let new = UInt32(truncatingIfNeeded: cur + delta)
            data.replaceSubrange(off..<off+4, with: new.beBytes)
            off += 4
        }
    }

    private static func patchCo64(data: inout Data, start: Int, end: Int, delta: Int64) {
        guard start + 8 <= end else { return }
        let count = Int(data.subdata(in: start+4..<start+8).beUInt32)
        var off = start + 8
        for _ in 0..<count {
            guard off + 8 <= end else { return }
            let cur = Int64(bitPattern: data.subdata(in: off..<off+8).beUInt64)
            let new = UInt64(bitPattern: cur + delta)
            data.replaceSubrange(off..<off+8, with: new.beBytes)
            off += 8
        }
    }

    // MARK: - Tag <-> atom mapping

    static let atomToKey: [String: String] = [
        "\u{00A9}nam": "TITLE",
        "\u{00A9}ART": "ARTIST",
        "aART":        "ALBUMARTIST",
        "\u{00A9}alb": "ALBUM",
        "\u{00A9}day": "DATE",
        "\u{00A9}gen": "GENRE",
        "\u{00A9}wrt": "COMPOSER",
        "\u{00A9}cmt": "COMMENT",
        "\u{00A9}grp": "GROUPING",
        "\u{00A9}lyr": "LYRICS",
    ]
    static let keyToAtom: [String: String] = {
        var m: [String: String] = [:]
        for (a, k) in atomToKey { m[k] = a }
        return m
    }()

    static let id3v1Genres: [String] = [
        "Blues","Classic Rock","Country","Dance","Disco","Funk","Grunge","Hip-Hop","Jazz",
        "Metal","New Age","Oldies","Other","Pop","R&B","Rap","Reggae","Rock","Techno",
        "Industrial","Alternative","Ska","Death Metal","Pranks","Soundtrack","Euro-Techno",
        "Ambient","Trip-Hop","Vocal","Jazz+Funk","Fusion","Trance","Classical","Instrumental",
        "Acid","House","Game","Sound Clip","Gospel","Noise","AlternRock","Bass","Soul","Punk",
        "Space","Meditative","Instrumental Pop","Instrumental Rock","Ethnic","Gothic","Darkwave",
        "Techno-Industrial","Electronic","Pop-Folk","Eurodance","Dream","Southern Rock","Comedy",
        "Cult","Gangsta","Top 40","Christian Rap","Pop/Funk","Jungle","Native American","Cabaret",
        "New Wave","Psychadelic","Rave","Showtunes","Trailer","Lo-Fi","Tribal","Acid Punk",
        "Acid Jazz","Polka","Retro","Musical","Rock & Roll","Hard Rock"
    ]
}

// MARK: - Atom

fileprivate struct Atom {
    let type: String
    /// Absolute byte offset of the atom header in the file.
    let start: UInt64
    /// Absolute byte offset just past the atom (start + size).
    let end: UInt64
    /// Children (only populated for known container types).
    let children: [Atom]
    /// Source: nil = comes from the on-disk file (use file handle / range).
    let inMemory: Data?

    func readPayload(from url: URL) -> Data {
        if let d = inMemory { return d.subdata(in: 8..<d.count) }
        guard let h = try? FileHandle(forReadingFrom: url) else { return Data() }
        defer { try? h.close() }
        do {
            try h.seek(toOffset: start + 8)
            return try h.read(upToCount: Int(end - start - 8)) ?? Data()
        } catch { return Data() }
    }

    func fullBytes(in container: Data) -> Data {
        // For atoms parsed from an in-memory container, return the slice.
        return container.subdata(in: Int(start)..<Int(end))
    }

    func childContainer(type: String) -> Atom? {
        children.first(where: { $0.type == type })
    }

    /// `meta` is a full-box: skip 4 bytes of version+flags before parsing
    /// children. (Implemented inside the parser so this just looks them up.)
    func childMeta() -> Atom? {
        children.first(where: { $0.type == "meta" })
    }
}

// MARK: - Parser

fileprivate enum AtomParser {

    /// Container types whose children we recurse into when reading.
    static let containers: Set<String> = [
        "moov", "trak", "mdia", "minf", "stbl", "udta", "meta", "ilst",
        // ilst tag children — they themselves contain `data` (and mean/name).
        "\u{00A9}nam","\u{00A9}ART","aART","\u{00A9}alb","\u{00A9}day","\u{00A9}gen",
        "\u{00A9}wrt","\u{00A9}cmt","\u{00A9}grp","\u{00A9}lyr",
        "trkn","disk","gnre","covr","----"
    ]

    /// Parse sibling atoms from a file handle in [start, end).
    static func parseSiblings(handle: FileHandle, start: UInt64, end: UInt64) throws -> [Atom] {
        var out: [Atom] = []
        var p = start
        while p + 8 <= end {
            try handle.seek(toOffset: p)
            guard let header = try handle.read(upToCount: 8), header.count == 8 else { break }
            var size = UInt64(header.subdata(in: 0..<4).beUInt32)
            let type = String(data: header.subdata(in: 4..<8), encoding: .isoLatin1) ?? "????"
            var headerLen: UInt64 = 8
            if size == 1 {
                guard let ext = try handle.read(upToCount: 8), ext.count == 8 else { break }
                size = ext.beUInt64
                headerLen = 16
            } else if size == 0 {
                size = end - p
            }
            guard size >= headerLen, p + size <= end else { break }
            let atomEnd = p + size

            var children: [Atom] = []
            if containers.contains(type) {
                var childStart = p + headerLen
                if type == "meta" { childStart += 4 } // full box
                children = try parseSiblings(handle: handle, start: childStart, end: atomEnd)
            }
            out.append(Atom(type: type, start: p, end: atomEnd, children: children, inMemory: nil))
            p = atomEnd
        }
        return out
    }

    /// Parse sibling atoms from an in-memory `Data` slice. Returns shallow
    /// atoms with absolute offsets relative to the slice's start.
    static func parseInMemorySiblings(_ data: Data) -> [Atom] {
        var out: [Atom] = []
        var p = 0
        let end = data.count
        while p + 8 <= end {
            let size32 = Int(data.subdata(in: p..<p+4).beUInt32)
            let type = String(data: data.subdata(in: p+4..<p+8), encoding: .isoLatin1) ?? "????"
            var size = size32
            var headerLen = 8
            if size32 == 1, p + 16 <= end {
                size = Int(data.subdata(in: p+8..<p+16).beUInt64)
                headerLen = 16
            } else if size32 == 0 {
                size = end - p
            }
            if size < headerLen || p + size > end { break }
            let atomEnd = p + size
            // Slice for this atom (full bytes including header).
            let slice = data.subdata(in: p..<atomEnd)
            out.append(Atom(type: type,
                            start: UInt64(p), end: UInt64(atomEnd),
                            children: [], inMemory: slice))
            p = atomEnd
        }
        return out
    }
}

// MARK: - Data / numeric helpers (file-private to avoid clashing with FlacFile/ID3v2)

fileprivate extension Data {
    var beUInt32: UInt32 {
        guard count >= 4 else { return 0 }
        return withUnsafeBytes { raw -> UInt32 in
            let p = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            return (UInt32(p[0]) << 24) | (UInt32(p[1]) << 16) |
                   (UInt32(p[2]) << 8)  |  UInt32(p[3])
        }
    }
    var beUInt64: UInt64 {
        guard count >= 8 else { return 0 }
        return withUnsafeBytes { raw -> UInt64 in
            let p = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            var v: UInt64 = 0
            for i in 0..<8 { v = (v << 8) | UInt64(p[i]) }
            return v
        }
    }
    mutating func append(beUInt32 v: UInt32) {
        append(contentsOf: [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF),
                            UInt8(v >> 8  & 0xFF), UInt8(v       & 0xFF)])
    }
    mutating func append(beUInt16 v: UInt16) {
        append(contentsOf: [UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)])
    }
}

fileprivate extension UInt32 {
    var beBytes: [UInt8] {
        [UInt8(self >> 24 & 0xFF), UInt8(self >> 16 & 0xFF),
         UInt8(self >> 8  & 0xFF), UInt8(self       & 0xFF)]
    }
}

fileprivate extension UInt64 {
    var beBytes: [UInt8] {
        var out = [UInt8](repeating: 0, count: 8)
        for i in 0..<8 { out[i] = UInt8((self >> (56 - i*8)) & 0xFF) }
        return out
    }
}
