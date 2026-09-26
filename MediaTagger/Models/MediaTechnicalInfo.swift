import Foundation

/// Technical (audio/container) properties surfaced in the Info panel.
/// All fields are optional — readers fill in whatever they can determine
/// without touching audio frames beyond the format header.
struct MediaTechnicalInfo: Equatable {
    /// Container / file format (e.g. "FLAC", "MP3", "MP4", "DSF").
    var container: String?
    /// Audio codec name (e.g. "FLAC", "AAC", "ALAC", "MP3", "DSD", "PCM").
    var codec: String?
    /// Samples per second (Hz). For DSD this is the DSD sample rate (2.8224 MHz, 5.6448 MHz, …).
    var sampleRate: Double?
    /// Bits per sample (PCM only; 1 for DSD).
    var bitsPerSample: Int?
    /// Number of audio channels.
    var channels: Int?
    /// Average bitrate in bits per second.
    var bitrate: Double?
    /// Track duration in seconds.
    var durationSeconds: Double?
    /// File size on disk in bytes.
    var fileSizeBytes: Int64?
    /// True if the source is DSD (1-bit) instead of PCM.
    var isDSD: Bool = false
    /// True if the source is a still image (no audio).
    var isImage: Bool = false
    /// Image dimensions in pixels (still images only).
    var pixelWidth: Int?
    var pixelHeight: Int?
    /// Image color model (e.g. "RGB", "Gray", "CMYK").
    var colorModel: String?

    var formattedDuration: String? {
        guard let duration = durationSeconds, duration.isFinite, duration > 0,
              let total = Int(exactly: duration.rounded()) else { return nil }
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        let secondsText = seconds < 10 ? "0\(seconds)" : "\(seconds)"
        if hours > 0 {
            let minutesText = minutes < 10 ? "0\(minutes)" : "\(minutes)"
            return "\(hours):\(minutesText):\(secondsText)"
        }
        return "\(minutes):\(secondsText)"
    }
}
