import XCTest
import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import MediaTagger

/// End-to-end EXIF/TIFF read/write tests for the ImageFile / MetadataService
/// image code path. Generates a tiny synthetic JPEG on disk so the test has
/// no fixture dependencies.
final class ImageFileWriteRoundTripTests: XCTestCase {

    private var fileURL: URL!

    override func setUpWithError() throws {
        fileURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MediaTaggerTest-\(UUID().uuidString).jpg")
        try writeSyntheticJPEG(to: fileURL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: fileURL)
    }

    func testReadsDimensionsAndEmptyMetadata() throws {
        let info = try ImageFile.read(fileURL)
        XCTAssertEqual(info.pixelWidth, 8)
        XCTAssertEqual(info.pixelHeight, 8)
        XCTAssertNotNil(info.formatName)
    }

    func testWriteThenReadStandardImageTags() throws {
        // Use the canonical landing keys (ImageIO auto-syncs TIFF:Artist ->
        // IPTC:Byline, TIFF:ImageDescription -> IPTC:Caption/Abstract, etc.).
        let entries: [(key: String, value: String)] = [
            ("IPTC:Byline",            "Tester"),
            ("TIFF:Copyright",         "© 2026"),
            ("IPTC:Caption/Abstract",  "Hello EXIF"),
            ("EXIF:DateTimeOriginal",  "2026:01:02 03:04:05"),
            ("EXIF:UserComment",       "round trip"),
            ("GPS:Latitude",           "37.7749"),
            ("GPS:Longitude",          "-122.4194"),
        ]
        try ImageFile.write(url: fileURL, entries: entries)

        let info = try ImageFile.read(fileURL)
        let kv = Dictionary(uniqueKeysWithValues: info.entries.map { ($0.key, $0.value) })
        XCTAssertEqual(kv["IPTC:Byline"], "Tester")
        XCTAssertEqual(kv["TIFF:Copyright"], "© 2026")
        XCTAssertEqual(kv["IPTC:Caption/Abstract"], "Hello EXIF")
        XCTAssertEqual(kv["EXIF:DateTimeOriginal"], "2026:01:02 03:04:05")
        XCTAssertEqual(kv["EXIF:UserComment"], "round trip")
        if let lat = kv["GPS:Latitude"] {
            XCTAssertEqual(Double(lat) ?? 0, 37.7749, accuracy: 0.001)
        } else {
            XCTFail("GPS:Latitude missing after round trip")
        }
        // ImageIO splits signed longitude into magnitude + reference ("W"/"E").
        if let lon = kv["GPS:Longitude"] {
            XCTAssertEqual(abs(Double(lon) ?? 0), 122.4194, accuracy: 0.001)
        } else {
            XCTFail("GPS:Longitude missing after round trip")
        }
        XCTAssertEqual(kv["GPS:LongitudeRef"], "W")
    }

    func testWriteThroughMetadataService() throws {
        let svc = MetadataService()
        var md = try svc.read(fileURL)
        md.setTag("IPTC:Byline", "Service Path")
        md.setTag("EXIF:DateTimeOriginal", "2026:05:12 10:00:00")
        try svc.write(md, to: fileURL)

        let again = try svc.read(fileURL)
        XCTAssertEqual(again.first("IPTC:Byline"), "Service Path")
        XCTAssertEqual(again.first("EXIF:DateTimeOriginal"), "2026:05:12 10:00:00")
    }

    // MARK: - Synthetic JPEG helper

    private func writeSyntheticJPEG(to url: URL) throws {
        let size = 8
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: 0, space: cs,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            throw NSError(domain: "test", code: 1)
        }
        ctx.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        guard let cgImage = ctx.makeImage() else { throw NSError(domain: "test", code: 2) }

        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil
        ) else { throw NSError(domain: "test", code: 3) }
        CGImageDestinationAddImage(dest, cgImage, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }
}
