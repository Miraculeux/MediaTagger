import Foundation

struct MediaFile: Identifiable, Hashable {
    let id: URL
    var url: URL { id }
    var name: String { url.lastPathComponent }
    var ext: String { url.pathExtension.lowercased() }

    static let supportedExtensions: Set<String> = [
        "flac", "mp3", "m4a", "aac", "alac", "wav", "aiff", "aif", "ogg", "opus"
    ]

    static func isSupported(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }
}
