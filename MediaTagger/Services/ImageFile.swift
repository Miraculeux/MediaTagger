import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
import AppKit

/// ImageIO-backed reader/writer for EXIF / TIFF / IPTC / GPS metadata.
///
/// Tag entries are flattened into `PREFIX:KEY` strings (e.g. `EXIF:DateTimeOriginal`,
/// `TIFF:Artist`, `GPS:Latitude`, `IPTC:ObjectName`). When writing, the prefix
/// determines which container the entry is written back into. Pixel data is
/// preserved by copying the image from the source unchanged — only the
/// metadata dictionary is rewritten.
struct ImageFile {

    /// Property-dictionary key prefixes (without surrounding braces) that
    /// ImageIO uses for nested metadata sub-dictionaries.
    enum Namespace: String, CaseIterable {
        case exif = "EXIF"
        case tiff = "TIFF"
        case gps  = "GPS"
        case iptc = "IPTC"
        case exifAux = "EXIFAUX"
        case png  = "PNG"

        var dictKey: CFString {
            switch self {
            case .exif:    return kCGImagePropertyExifDictionary
            case .tiff:    return kCGImagePropertyTIFFDictionary
            case .gps:     return kCGImagePropertyGPSDictionary
            case .iptc:    return kCGImagePropertyIPTCDictionary
            case .exifAux: return kCGImagePropertyExifAuxDictionary
            case .png:     return kCGImagePropertyPNGDictionary
            }
        }

        static func from(prefix: String) -> Namespace? {
            Namespace(rawValue: prefix.uppercased())
        }
    }

    // MARK: - Read result

    struct Info {
        var entries: [(key: String, value: String)] = []
        var pixelWidth: Int?
        var pixelHeight: Int?
        var depth: Int?
        var colorModel: String?
        var dpi: Int?
        var orientation: Int?
        var formatName: String?
        var utType: String?
    }

    // MARK: - Read

    static func read(_ url: URL) throws -> Info {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw NSError(domain: "MediaTagger.ImageFile", code: 1,
                          userInfo: [NSLocalizedDescriptionKey:
                            "Unable to open image \(url.lastPathComponent)"])
        }
        let props = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:]

        var info = Info()
        info.pixelWidth  = (props[kCGImagePropertyPixelWidth]  as? NSNumber)?.intValue
        info.pixelHeight = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        info.depth       = (props[kCGImagePropertyDepth]       as? NSNumber)?.intValue
        info.colorModel  =  props[kCGImagePropertyColorModel]  as? String
        if let dpi = props[kCGImagePropertyDPIWidth] as? NSNumber {
            info.dpi = dpi.intValue
        }
        info.orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue

        if let uti = CGImageSourceGetType(src) as String? {
            info.utType = uti
            info.formatName = formatName(forUTI: uti)
        }

        for ns in Namespace.allCases {
            guard let sub = props[ns.dictKey] as? [CFString: Any] else { continue }
            for (k, v) in sub {
                let keyName = (k as String)
                if let str = stringValue(from: v) {
                    info.entries.append((key: "\(ns.rawValue):\(keyName)", value: str))
                }
            }
        }
        // Stable order for the UI (group by namespace, then alphabetical).
        info.entries.sort { lhs, rhs in
            if lhs.key == rhs.key { return false }
            return lhs.key.localizedStandardCompare(rhs.key) == .orderedAscending
        }
        return info
    }

    // MARK: - Write

    /// Replace metadata on `url` with `entries`. Entries are dispatched into
    /// EXIF/TIFF/GPS/IPTC sub-dictionaries based on their `PREFIX:KEY` form.
    /// Unprefixed entries are dropped (they have no place in an image file).
    static func write(url: URL, entries: [(key: String, value: String)]) throws {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw NSError(domain: "MediaTagger.ImageFile", code: 2,
                          userInfo: [NSLocalizedDescriptionKey:
                            "Unable to open image \(url.lastPathComponent)"])
        }
        guard let uti = CGImageSourceGetType(src) else {
            throw NSError(domain: "MediaTagger.ImageFile", code: 3,
                          userInfo: [NSLocalizedDescriptionKey:
                            "Unknown image format for \(url.lastPathComponent)"])
        }

        // Start from the existing properties so unrelated keys (camera
        // settings, color profile metadata, etc.) are preserved.
        var props = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:]

        // Reset the namespaces we manage; rebuild them from entries.
        for ns in Namespace.allCases {
            props.removeValue(forKey: ns.dictKey)
        }

        var nsBuckets: [Namespace: [CFString: Any]] = [:]
        for entry in entries {
            let parts = entry.key.split(separator: ":", maxSplits: 1,
                                        omittingEmptySubsequences: false)
            guard parts.count == 2,
                  let ns = Namespace.from(prefix: String(parts[0]))
            else { continue }
            let tagName = String(parts[1])
            let cfKey = tagName as CFString
            let coerced = coerce(value: entry.value, forKey: cfKey, namespace: ns)
            var bucket = nsBuckets[ns] ?? [:]
            bucket[cfKey] = coerced
            nsBuckets[ns] = bucket
        }
        for (ns, bucket) in nsBuckets where !bucket.isEmpty {
            props[ns.dictKey] = bucket as CFDictionary
        }

        // Write to a sibling temp file, then atomically replace the original.
        let tmpURL = url.deletingLastPathComponent()
            .appendingPathComponent(".mediatagger-\(UUID().uuidString).tmp")

        guard let dst = CGImageDestinationCreateWithURL(tmpURL as CFURL, uti, 1, nil) else {
            throw NSError(domain: "MediaTagger.ImageFile", code: 4,
                          userInfo: [NSLocalizedDescriptionKey:
                            "Unable to create image destination"])
        }
        CGImageDestinationAddImageFromSource(dst, src, 0, props as CFDictionary)
        guard CGImageDestinationFinalize(dst) else {
            try? FileManager.default.removeItem(at: tmpURL)
            throw NSError(domain: "MediaTagger.ImageFile", code: 5,
                          userInfo: [NSLocalizedDescriptionKey:
                            "Failed to write image metadata"])
        }

        // Atomic replace.
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmpURL)
    }

    // MARK: - Helpers

    private static func stringValue(from any: Any) -> String? {
        if let s = any as? String { return s }
        if let n = any as? NSNumber {
            // Distinguish integers from floats to keep round-trips clean.
            if CFNumberIsFloatType(n) {
                return String(format: "%g", n.doubleValue)
            }
            return n.stringValue
        }
        if let arr = any as? [Any] {
            let parts = arr.compactMap { stringValue(from: $0) }
            return parts.joined(separator: ", ")
        }
        if let date = any as? Date {
            let fmt = ISO8601DateFormatter()
            return fmt.string(from: date)
        }
        return nil
    }

    /// Heuristic conversion of a user-entered string back into a typed value
    /// suitable for an ImageIO property dictionary. Keys ImageIO expects to
    /// be numeric (GPS latitude/longitude, EXIF FNumber, ISO, …) are parsed
    /// as Double; everything else stays as a String.
    private static func coerce(value: String,
                               forKey key: CFString,
                               namespace: Namespace) -> Any {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let keyStr = (key as String)

        // Comma-separated list -> array (e.g. ISOSpeedRatings, Keywords).
        if trimmed.contains(",") {
            let parts = trimmed.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            // Numeric array (all parts parse as Double)?
            if namespace == .exif || namespace == .gps {
                let nums = parts.compactMap { Double($0) }
                if nums.count == parts.count {
                    return nums as CFArray
                }
            }
            return parts as CFArray
        }

        if numericKeys.contains(keyStr) {
            if let d = Double(trimmed) { return NSNumber(value: d) }
        }
        if integerKeys.contains(keyStr) {
            if let i = Int(trimmed) { return NSNumber(value: i) }
        }
        return trimmed
    }

    private static let integerKeys: Set<String> = [
        "Orientation", "ResolutionUnit", "YCbCrPositioning",
        "ColorSpace", "PixelXDimension", "PixelYDimension",
        "ISOSpeedRatings", "ISOSpeed", "MeteringMode", "Flash",
        "ExposureProgram", "WhiteBalance", "SceneCaptureType",
        "GainControl", "Contrast", "Saturation", "Sharpness",
        "SubjectDistanceRange", "SensingMethod", "CustomRendered",
        "ExposureMode", "FocalLengthIn35mmFilm",
    ]

    private static let numericKeys: Set<String> = [
        "XResolution", "YResolution",
        "FNumber", "ApertureValue", "MaxApertureValue",
        "ExposureTime", "ShutterSpeedValue",
        "FocalLength", "DigitalZoomRatio", "BrightnessValue",
        "ExposureBiasValue", "SubjectDistance",
        "Latitude", "Longitude", "Altitude",
        "DestLatitude", "DestLongitude",
        "Speed", "Track", "ImgDirection",
    ]

    private static func formatName(forUTI uti: String) -> String? {
        switch uti.lowercased() {
        case "public.jpeg":                  return "JPEG"
        case "public.png":                   return "PNG"
        case "public.tiff":                  return "TIFF"
        case "com.compuserve.gif":           return "GIF"
        case "public.heic":                  return "HEIC"
        case "public.heif", "public.heif-standard": return "HEIF"
        default:
            if let type = UTType(uti) {
                return type.preferredFilenameExtension?.uppercased()
                    ?? type.localizedDescription
            }
            return nil
        }
    }
}
