import Foundation

// MARK: - MediaMetadata helpers

extension MediaMetadata {
    /// Set or replace the (first) tag with the given key. Pass `nil` value to remove all entries with that key.
    mutating func setTag(_ key: String, _ value: String?) {
        let upper = key.uppercased()
        if let value {
            if let idx = tags.firstIndex(where: { $0.key.caseInsensitiveCompare(upper) == .orderedSame }) {
                tags[idx].value = value
                let keepID = tags[idx].id
                // Drop further duplicates so we end up with exactly one.
                tags.removeAll(where: { $0.key.caseInsensitiveCompare(upper) == .orderedSame && $0.id != keepID })
            } else {
                tags.append(.init(key: upper, value: value))
            }
        } else {
            tags.removeAll { $0.key.caseInsensitiveCompare(upper) == .orderedSame }
        }
    }
}

// MARK: - Filename cleanup

struct FilenameCleanupOptions: Equatable {
    var stripLeadingTrackNumber: Bool = true
    var underscoresToSpaces: Bool = true
    var collapseWhitespace: Bool = true
    var trim: Bool = true
}

enum FilenameCleaner {
    /// Returns a cleaned-up title from a filename. Always strips the extension.
    static func title(from filename: String, options: FilenameCleanupOptions = .init()) -> String {
        var s = (filename as NSString).deletingPathExtension

        if options.stripLeadingTrackNumber {
            // Match: optional disc-track ("1-02", "01.02"), or simple "01", followed by separator.
            // Examples removed: "01 ", "01-", "01.", "1.02 ", "12 - "
            let pattern = #"^\s*(\d{1,2}([\-._]\d{1,3})?)[\s\-._]+"#
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(s.startIndex..., in: s)
                s = regex.stringByReplacingMatches(in: s, range: range, withTemplate: "")
            }
        }
        if options.underscoresToSpaces {
            s = s.replacingOccurrences(of: "_", with: " ")
        }
        if options.collapseWhitespace,
           let regex = try? NSRegularExpression(pattern: #"\s+"#) {
            let range = NSRange(s.startIndex..., in: s)
            s = regex.stringByReplacingMatches(in: s, range: range, withTemplate: " ")
        }
        if options.trim {
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return s
    }
}

// MARK: - Track numbering

struct TrackNumberingOptions: Equatable {
    var startAt: Int = 1
    /// If true, write `TRACKTOTAL` equal to total selected files.
    var writeTotal: Bool = true
    /// If > 0, zero-pad to this width (e.g. width 2 -> "01").
    var zeroPadWidth: Int = 0

    func formatted(_ n: Int) -> String {
        zeroPadWidth > 0 ? String(format: "%0\(zeroPadWidth)d", n) : "\(n)"
    }
}

// MARK: - Batch plan

/// A declarative description of a batch edit. Each non-nil field is applied;
/// nil fields are left untouched on the per-file metadata.
struct BatchPlan {
    var titleFromFilename: FilenameCleanupOptions?   // if non-nil, derive TITLE from filename
    var album: String?
    var albumArtist: String?
    var artist: String?
    var date: String?
    var genre: String?
    var discNumber: String?
    var discTotal: String?
    var renumberTracks: TrackNumberingOptions?       // if non-nil, set TRACKNUMBER (and optionally TRACKTOTAL)
    var coverArt: Data?                              // if non-nil, replace cover art
    var coverMime: String?
    var clearCoverArt: Bool = false                  // if true (and coverArt nil), remove cover

    /// True if at least one operation is configured.
    var hasAnyOperation: Bool {
        titleFromFilename != nil
            || album != nil || albumArtist != nil || artist != nil
            || date != nil || genre != nil
            || discNumber != nil || discTotal != nil
            || renumberTracks != nil
            || coverArt != nil || clearCoverArt
    }

    func apply(to md: inout MediaMetadata, file: MediaFile, indexInSelection: Int, totalInSelection: Int) {
        if let opts = titleFromFilename {
            md.setTag("TITLE", FilenameCleaner.title(from: file.name, options: opts))
        }
        if let v = album { md.setTag("ALBUM", v) }
        if let v = albumArtist { md.setTag("ALBUMARTIST", v) }
        if let v = artist { md.setTag("ARTIST", v) }
        if let v = date { md.setTag("DATE", v) }
        if let v = genre { md.setTag("GENRE", v) }
        if let v = discNumber { md.setTag("DISCNUMBER", v) }
        if let v = discTotal { md.setTag("DISCTOTAL", v) }
        if let opts = renumberTracks {
            let n = opts.startAt + indexInSelection
            md.setTag("TRACKNUMBER", opts.formatted(n))
            if opts.writeTotal {
                md.setTag("TRACKTOTAL", opts.formatted(totalInSelection))
            }
        }
        if let data = coverArt {
            md.coverArt = data
            md.coverMimeType = coverMime ?? md.coverMimeType
        } else if clearCoverArt {
            md.coverArt = nil
            md.coverMimeType = nil
        }
    }
}
