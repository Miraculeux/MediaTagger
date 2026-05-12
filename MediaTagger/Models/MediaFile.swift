import Foundation

struct MediaFile: Identifiable, Hashable {
    let id: URL
    var url: URL { id }
    var name: String { url.lastPathComponent }
    var ext: String { url.pathExtension.lowercased() }

    /// Extensions we list and try to read. Writing is supported for a subset
    /// (see `MetadataService.write`); other formats are read-only via AVFoundation.
    static let supportedExtensions: Set<String> = [
        // Audio
        "flac", "mp3", "m4a", "m4b", "aac", "alac",
        "wav", "aiff", "aif", "aifc", "ogg", "opus",
        "mka", "dsf", "dff",
        // Video
        "mp4", "m4v", "mov", "mkv", "webm", "avi",
        // Images (EXIF/IPTC/TIFF/GPS via ImageIO)
        "jpg", "jpeg", "tif", "tiff", "heic", "heif", "png", "gif",
    ]

    /// Extensions handled by the image (EXIF) code path.
    static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "tif", "tiff", "heic", "heif", "png", "gif",
    ]

    static func isSupported(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    static func isImage(_ url: URL) -> Bool {
        imageExtensions.contains(url.pathExtension.lowercased())
    }

    var isImage: Bool { Self.isImage(url) }
}
