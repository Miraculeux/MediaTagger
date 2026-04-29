import Foundation

/// Metadata representation that's editor-friendly: ordered list of tag entries,
/// plus optional cover art. Mirrors Vorbis comments naturally; AV-based formats
/// are mapped to a small set of standard keys.
struct MediaMetadata: Equatable {
    struct Tag: Identifiable, Equatable {
        let id = UUID()
        var key: String
        var value: String
    }

    var vendor: String?
    var tags: [Tag] = []
    var coverArt: Data?
    var coverMimeType: String?

    /// Convenience accessors for common keys (case-insensitive).
    func first(_ key: String) -> String? {
        tags.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
    }

    var title: String? { first("TITLE") }
    var artist: String? { first("ARTIST") }
    var album: String? { first("ALBUM") }
    var trackNumber: String? { first("TRACKNUMBER") }
    var discNumber: String? { first("DISCNUMBER") }

    /// "03 / 12" style. Handles a `TRACKNUMBER` value that itself contains a slash
    /// (e.g. "3/12") as well as a separate `TRACKTOTAL`.
    var trackDisplay: String? {
        formattedNumber(value: first("TRACKNUMBER"), total: first("TRACKTOTAL"))
    }

    var discDisplay: String? {
        formattedNumber(value: first("DISCNUMBER"), total: first("DISCTOTAL"))
    }

    private func formattedNumber(value: String?, total: String?) -> String? {
        guard let raw = value?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if raw.contains("/") {
            let parts = raw.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 { return "\(parts[0]) / \(parts[1])" }
            return raw
        }
        if let t = total?.trimmingCharacters(in: .whitespaces), !t.isEmpty {
            return "\(raw) / \(t)"
        }
        return raw
    }
}

/// Standard Vorbis comment keys we surface in the UI.
enum StandardTagKey: String, CaseIterable {
    case title       = "TITLE"
    case artist      = "ARTIST"
    case albumArtist = "ALBUMARTIST"
    case album       = "ALBUM"
    case date        = "DATE"
    case genre       = "GENRE"
    case trackNumber = "TRACKNUMBER"
    case trackTotal  = "TRACKTOTAL"
    case discNumber  = "DISCNUMBER"
    case discTotal   = "DISCTOTAL"
    case composer    = "COMPOSER"
    case comment     = "COMMENT"
}
