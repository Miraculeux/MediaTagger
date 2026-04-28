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
        default:     return try readAVAsset(url)
        }
    }

    func readTitle(of url: URL) throws -> String? {
        try read(url).title
    }

    func write(_ md: MediaMetadata, to url: URL) throws {
        switch url.pathExtension.lowercased() {
        case "flac": try writeFlac(md, to: url)
        default: throw NSError(
            domain: "MusicTagger", code: 1,
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
            vendor: md.vendor ?? "MusicTagger",
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
