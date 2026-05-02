import Foundation
import AVFoundation
import CoreMedia

/// Helpers that build `MediaTechnicalInfo` from already-parsed format objects
/// (FLAC / DSF / DFF) or — as a fallback — from `AVURLAsset` for everything
/// else (MP3, AIFF, MP4/M4A, MKV, AVI, …).
///
/// All format-specific helpers are pure: they take pre-parsed inputs and do
/// no extra IO, so the same file scan that produced metadata can produce
/// tech info "for free". The AV fallback is `async` and uses native Swift
/// concurrency — no semaphores, no thread-bridging.
enum TechnicalInfoService {

    // MARK: FLAC (from a parsed FlacFile)

    static func from(flac file: FlacFile, fileSize: Int64?) -> MediaTechnicalInfo {
        var info = MediaTechnicalInfo()
        info.container = "FLAC"
        info.codec = "FLAC"
        info.fileSizeBytes = fileSize

        guard let block = file.blocks.first(where: { $0.type == FlacBlockType.streamInfo }),
              block.data.count >= 18
        else { return info }

        let d = block.data
        // Bytes 10..17 hold a 64-bit big-endian field laid out as:
        //   20 bits  sample rate (Hz)
        //    3 bits  channels-1
        //    5 bits  bits per sample - 1
        //   36 bits  total samples
        let b10 = UInt64(d[10]), b11 = UInt64(d[11]), b12 = UInt64(d[12])
        let b13 = UInt64(d[13]), b14 = UInt64(d[14]), b15 = UInt64(d[15])
        let b16 = UInt64(d[16]), b17 = UInt64(d[17])

        let sampleRate = (b10 << 12) | (b11 << 4) | (b12 >> 4)
        let channels = ((b12 >> 1) & 0x07) + 1
        let bitsPerSample = (((b12 & 0x01) << 4) | (b13 >> 4)) + 1
        let totalSamples = ((b13 & 0x0F) << 32) | (b14 << 24) | (b15 << 16) | (b16 << 8) | b17

        info.sampleRate = Double(sampleRate)
        info.channels = Int(channels)
        info.bitsPerSample = Int(bitsPerSample)
        if sampleRate > 0 {
            info.durationSeconds = Double(totalSamples) / Double(sampleRate)
        }
        if let size = fileSize, let dur = info.durationSeconds, dur > 0 {
            info.bitrate = Double(size) * 8.0 / dur
        }
        return info
    }

    // MARK: DSF / DFF (already populated by their readers — just stamp file size)

    static func from(dsf file: DSFFile, fileSize: Int64?) -> MediaTechnicalInfo {
        var info = file.techInfo
        info.fileSizeBytes = fileSize
        return info
    }

    static func from(dff file: DFFFile, fileSize: Int64?) -> MediaTechnicalInfo {
        var info = file.techInfo
        info.fileSizeBytes = fileSize
        return info
    }

    // MARK: AVAsset fallback (async)

    /// Async tech-info extraction for formats with no native parser. Uses
    /// `AVURLAsset.load(...)` directly, awaiting each value rather than
    /// blocking a worker thread on a `DispatchSemaphore`.
    static func avFallback(_ url: URL,
                           container: String?,
                           fileSize: Int64?) async -> MediaTechnicalInfo {
        var info = MediaTechnicalInfo()
        info.container = container
        info.fileSizeBytes = fileSize

        let asset = AVURLAsset(url: url)
        if let dur = try? await asset.load(.duration), dur.isNumeric {
            info.durationSeconds = CMTimeGetSeconds(dur)
        }
        if let track = try? await asset.loadTracks(withMediaType: .audio).first {
            if let rate = try? await track.load(.estimatedDataRate), rate > 0 {
                info.bitrate = Double(rate)
            }
            if let descs = try? await track.load(.formatDescriptions),
               let desc = descs.first,
               let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee {
                if asbd.mSampleRate > 0 { info.sampleRate = asbd.mSampleRate }
                if asbd.mChannelsPerFrame > 0 { info.channels = Int(asbd.mChannelsPerFrame) }
                if asbd.mBitsPerChannel > 0 { info.bitsPerSample = Int(asbd.mBitsPerChannel) }
                info.codec = codecName(asbd.mFormatID)
            }
        }
        return finalize(info)
    }

    // MARK: Common finishing pass

    /// Fill in derived fields (e.g. bitrate from file size + duration) when
    /// the source didn't supply them directly.
    static func finalize(_ info: MediaTechnicalInfo) -> MediaTechnicalInfo {
        var out = info
        if out.bitrate == nil,
           let size = out.fileSizeBytes,
           let dur = out.durationSeconds, dur > 0 {
            out.bitrate = Double(size) * 8.0 / dur
        }
        if out.bitrate == nil,
           let sr = out.sampleRate,
           let ch = out.channels,
           let bps = out.bitsPerSample {
            out.bitrate = sr * Double(ch) * Double(bps)
        }
        return out
    }

    // MARK: -

    private static func codecName(_ id: AudioFormatID) -> String {
        switch id {
        case kAudioFormatLinearPCM:        return "PCM"
        case kAudioFormatMPEG4AAC:         return "AAC"
        case kAudioFormatMPEG4AAC_HE:      return "HE-AAC"
        case kAudioFormatMPEG4AAC_HE_V2:   return "HE-AACv2"
        case kAudioFormatMPEGLayer1:       return "MP1"
        case kAudioFormatMPEGLayer2:       return "MP2"
        case kAudioFormatMPEGLayer3:       return "MP3"
        case kAudioFormatAppleLossless:    return "ALAC"
        case kAudioFormatFLAC:             return "FLAC"
        case kAudioFormatOpus:             return "Opus"
        case kAudioFormatAC3:              return "AC-3"
        case kAudioFormatEnhancedAC3:      return "E-AC-3"
        default:
            // Decode the four-char-code into a readable string.
            let bytes = withUnsafeBytes(of: id.bigEndian) { Data($0) }
            if let s = String(data: bytes, encoding: .ascii)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !s.isEmpty {
                return s
            }
            return "Audio"
        }
    }
}
