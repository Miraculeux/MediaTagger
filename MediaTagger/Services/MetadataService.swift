import Foundation
import AVFoundation
import AppKit

/// Front-door for reading and writing media metadata.
/// FLAC is handled natively (full read+write); other formats are read via
/// `AVAsset` (read-only for now). Stage 2 can extend writing for MP3/M4A.
struct MetadataService {

    func read(_ url: URL) throws -> MediaMetadata {
        switch url.pathExtension.lowercased() {
        case "flac": return try readFlac(url)
        case "mp3":  return try readMP3(url)
        case "m4a", "m4b", "mp4", "m4v", "mov", "alac":
            return try readMP4(url)
        case "aiff", "aif", "aifc":
            return try readAIFF(url)
        case "mka", "mkv", "webm":
            return try readMatroska(url)
        case "avi":
            return try readAVI(url)
        case "dsf":
            return try readDSF(url)
        case "dff":
            return try readDFF(url)
        default:     return try readAVAsset(url)
        }
    }

    func readTitle(of url: URL) throws -> String? {
        try read(url).title
    }

    func write(_ md: MediaMetadata, to url: URL) throws {
        switch url.pathExtension.lowercased() {
        case "flac": try writeFlac(md, to: url)
        case "mp3":  try writeMP3(md, to: url)
        case "m4a", "m4b", "mp4", "m4v", "mov", "alac":
            try writeMP4(md, to: url)
        case "aiff", "aif", "aifc":
            try writeAIFF(md, to: url)
        case "mka", "mkv", "webm":
            try writeMatroska(md, to: url)
        case "avi":
            try writeAVI(md, to: url)
        case "dsf":
            try writeDSF(md, to: url)
        case "dff":
            try writeDFF(md, to: url)
        default: throw NSError(
            domain: "MediaTagger", code: 1,
            userInfo: [NSLocalizedDescriptionKey:
                "Writing tags for .\(url.pathExtension) is not supported yet."])
        }
    }

    // MARK: - FLAC

    private func readFlac(_ url: URL) throws -> MediaMetadata {
        let file = try FlacFile.read(url)
        let vc = file.vorbisComment
        var md = MediaMetadata(
            vendor: vc.vendor,
            tags: vc.entries.map { MediaMetadata.Tag(key: $0.key, value: $0.value) }
        )
        if let pic = file.firstPicture {
            md.coverArt = pic.data
            md.coverMimeType = pic.mimeType
        }
        return md
    }

    private func writeFlac(_ md: MediaMetadata, to url: URL) throws {
        var file = try FlacFile.read(url)
        let vc = VorbisComment(
            vendor: md.vendor ?? "MediaTagger",
            entries: md.tags.map { (key: $0.key.uppercased(), value: $0.value) }
        )
        file.setVorbisComment(vc)

        if let data = md.coverArt {
            let mime = md.coverMimeType ?? mimeForImageData(data) ?? "image/jpeg"
            let (w, h) = imageDimensions(data) ?? (0, 0)
            file.setFrontCover(FlacPicture(
                pictureType: 3,
                mimeType: mime,
                description: "",
                width: UInt32(w), height: UInt32(h),
                depth: 24, colors: 0,
                data: data
            ))
        }
        try file.write()
    }

    // MARK: - MP3 (ID3v2)

    private func readMP3(_ url: URL) throws -> MediaMetadata {
        let file = try ID3v2File.read(url)
        let (entries, cover) = file.decoded()
        var md = MediaMetadata(
            vendor: nil,
            tags: entries.map { MediaMetadata.Tag(key: $0.key, value: $0.value) }
        )
        if let cover {
            md.coverArt = cover.data
            md.coverMimeType = cover.mime
        }
        return md
    }

    private func writeMP3(_ md: MediaMetadata, to url: URL) throws {
        let entries = md.tags.map { (key: $0.key.uppercased(), value: $0.value) }
        let cover: (Data, String)?
        if let data = md.coverArt {
            cover = (data, md.coverMimeType ?? mimeForImageData(data) ?? "image/jpeg")
        } else {
            cover = nil
        }
        try ID3v2File.write(url: url, entries: entries, cover: cover)
    }

    // MARK: - MP4 / M4A (iTunes-style atoms)

    private func readMP4(_ url: URL) throws -> MediaMetadata {
        let file = try MP4File.read(url)
        let (entries, cover) = file.decoded()
        var md = MediaMetadata(
            vendor: nil,
            tags: entries.map { MediaMetadata.Tag(key: $0.key, value: $0.value) }
        )
        if let cover {
            md.coverArt = cover.data
            md.coverMimeType = cover.mime
        }
        return md
    }

    private func writeMP4(_ md: MediaMetadata, to url: URL) throws {
        let entries = md.tags.map { (key: $0.key.uppercased(), value: $0.value) }
        let cover: MP4File.Cover?
        if let data = md.coverArt {
            cover = MP4File.Cover(
                data: data,
                mime: md.coverMimeType ?? mimeForImageData(data) ?? "image/jpeg")
        } else {
            cover = nil
        }
        try MP4File.write(url: url, entries: entries, cover: cover)
    }

    // MARK: - AIFF (ID3v2 inside FORM)

    private func readAIFF(_ url: URL) throws -> MediaMetadata {
        let file = try AIFFFile.read(url)
        let (entries, cover) = file.decoded()
        var md = MediaMetadata(
            vendor: nil,
            tags: entries.map { MediaMetadata.Tag(key: $0.key, value: $0.value) }
        )
        if let cover {
            md.coverArt = cover.data
            md.coverMimeType = cover.mime
        }
        return md
    }

    private func writeAIFF(_ md: MediaMetadata, to url: URL) throws {
        let entries = md.tags.map { (key: $0.key.uppercased(), value: $0.value) }
        let cover: (Data, String)?
        if let data = md.coverArt {
            cover = (data, md.coverMimeType ?? mimeForImageData(data) ?? "image/jpeg")
        } else {
            cover = nil
        }
        try AIFFFile.write(url: url, entries: entries, cover: cover)
    }

    // MARK: - Matroska (MKV / MKA)

    private func readMatroska(_ url: URL) throws -> MediaMetadata {
        let file = try MatroskaFile.read(url)
        var md = MediaMetadata(
            vendor: nil,
            tags: file.entries.map { MediaMetadata.Tag(key: $0.key, value: $0.value) }
        )
        if let cover = file.cover {
            md.coverArt = cover.data
            md.coverMimeType = cover.mime
        }
        return md
    }

    private func writeMatroska(_ md: MediaMetadata, to url: URL) throws {
        let entries = md.tags.map { (key: $0.key.uppercased(), value: $0.value) }
        let cover: (Data, String)?
        if let data = md.coverArt {
            cover = (data, md.coverMimeType ?? mimeForImageData(data) ?? "image/jpeg")
        } else {
            cover = nil
        }
        try MatroskaFile.write(url: url, entries: entries, cover: cover)
    }

    // MARK: - AVI (RIFF INFO)

    private func readAVI(_ url: URL) throws -> MediaMetadata {
        let file = try AVIFile.read(url)
        return MediaMetadata(
            vendor: nil,
            tags: file.entries.map { MediaMetadata.Tag(key: $0.key, value: $0.value) }
        )
    }

    private func writeAVI(_ md: MediaMetadata, to url: URL) throws {
        let entries = md.tags.map { (key: $0.key.uppercased(), value: $0.value) }
        try AVIFile.write(url: url, entries: entries)
    }

    // MARK: - DSF (DSD Stream File, ID3v2 trailer)

    private func readDSF(_ url: URL) throws -> MediaMetadata {
        let file = try DSFFile.read(url)
        let (entries, cover) = file.decoded()
        var md = MediaMetadata(
            vendor: nil,
            tags: entries.map { MediaMetadata.Tag(key: $0.key, value: $0.value) }
        )
        if let cover {
            md.coverArt = cover.data
            md.coverMimeType = cover.mime
        }
        return md
    }

    private func writeDSF(_ md: MediaMetadata, to url: URL) throws {
        let entries = md.tags.map { (key: $0.key.uppercased(), value: $0.value) }
        let cover: (Data, String)?
        if let data = md.coverArt {
            cover = (data, md.coverMimeType ?? mimeForImageData(data) ?? "image/jpeg")
        } else {
            cover = nil
        }
        try DSFFile.write(url: url, entries: entries, cover: cover)
    }

    // MARK: - DFF (DSDIFF, ID3v2 inside FRM8)

    private func readDFF(_ url: URL) throws -> MediaMetadata {
        let file = try DFFFile.read(url)
        let (entries, cover) = file.decoded()
        var md = MediaMetadata(
            vendor: nil,
            tags: entries.map { MediaMetadata.Tag(key: $0.key, value: $0.value) }
        )
        if let cover {
            md.coverArt = cover.data
            md.coverMimeType = cover.mime
        }
        return md
    }

    private func writeDFF(_ md: MediaMetadata, to url: URL) throws {
        let entries = md.tags.map { (key: $0.key.uppercased(), value: $0.value) }
        let cover: (Data, String)?
        if let data = md.coverArt {
            cover = (data, md.coverMimeType ?? mimeForImageData(data) ?? "image/jpeg")
        } else {
            cover = nil
        }
        try DFFFile.write(url: url, entries: entries, cover: cover)
    }

    // MARK: - AVAsset (read-only fallback)

    private func readAVAsset(_ url: URL) throws -> MediaMetadata {
        let asset = AVURLAsset(url: url)
        var tags: [MediaMetadata.Tag] = []
        var cover: Data?
        var coverMime: String?

        let semaphore = DispatchSemaphore(value: 0)
        var loadedItems: [AVMetadataItem] = []
        asset.loadValuesAsynchronously(forKeys: ["commonMetadata", "metadata"]) {
            loadedItems = asset.commonMetadata + asset.metadata
            semaphore.signal()
        }
        semaphore.wait()

        for item in loadedItems {
            let key = (item.commonKey?.rawValue ?? item.key as? String ?? "").uppercased()
            if key.isEmpty { continue }
            if let str = item.stringValue {
                tags.append(.init(key: mapCommonKey(key), value: str))
            } else if let data = item.dataValue, key.contains("ARTWORK") || key.contains("COVER") || key == "PIC" {
                cover = data
                coverMime = mimeForImageData(data)
            }
        }
        return MediaMetadata(vendor: nil, tags: tags, coverArt: cover, coverMimeType: coverMime)
    }

    private func mapCommonKey(_ k: String) -> String {
        switch k {
        case "TITLE": return "TITLE"
        case "ARTIST": return "ARTIST"
        case "ALBUMNAME", "ALBUM": return "ALBUM"
        case "TYPE": return "GENRE"
        case "CREATIONDATE", "DATE": return "DATE"
        default: return k
        }
    }

    // MARK: - Image helpers

    private func mimeForImageData(_ data: Data) -> String? {
        guard data.count >= 4 else { return nil }
        let b = [UInt8](data.prefix(4))
        if b[0] == 0xFF && b[1] == 0xD8 { return "image/jpeg" }
        if b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47 { return "image/png" }
        return nil
    }

    private func imageDimensions(_ data: Data) -> (Int, Int)? {
        guard let img = NSImage(data: data),
              let rep = img.representations.first
        else { return nil }
        return (rep.pixelsWide, rep.pixelsHigh)
    }
}
