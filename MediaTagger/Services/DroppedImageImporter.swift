import AppKit
import ImageIO
import UniformTypeIdentifiers

enum DroppedImageSource: Sendable {
    case url(URL)
    case data(Data, filename: String)
}

enum DroppedImageImporter {
    static let urlPasteboardType = NSPasteboard.PasteboardType(UTType.url.identifier)
    static let pasteboardTypes: [NSPasteboard.PasteboardType] = [.fileURL, urlPasteboardType, .png, .tiff]

    static func sources(from pasteboard: NSPasteboard) -> [DroppedImageSource] {
        var sources: [DroppedImageSource] = []
        var seenURLs: Set<URL> = []
        for item in pasteboard.pasteboardItems ?? [] {
            let url = [NSPasteboard.PasteboardType.fileURL, urlPasteboardType]
                .compactMap { item.string(forType: $0) }
                .compactMap { URL(string: $0) }
                .first { $0.isFileURL || ["https", "http"].contains($0.scheme?.lowercased() ?? "") }
            if let url, url.isFileURL {
                if seenURLs.insert(url).inserted { sources.append(.url(url)) }
            } else if let data = item.data(forType: .png) ?? item.data(forType: .tiff) {
                sources.append(.data(data, filename: url?.lastPathComponent ?? "image"))
            } else if let url, seenURLs.insert(url).inserted {
                sources.append(.url(url))
            }
        }
        return sources
    }

    static func importImage(
        _ source: DroppedImageSource,
        into folder: URL,
        session: URLSession = .shared
    ) async throws -> URL {
        let data: Data
        let filename: String
        switch source {
        case .data(let bytes, let name):
            data = bytes
            filename = name
        case .url(let url):
            if url.isFileURL {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                data = try Data(contentsOf: url)
                filename = url.lastPathComponent
            } else {
                guard ["https", "http"].contains(url.scheme?.lowercased() ?? "") else {
                    throw ImportError.unsupportedURL
                }
                let (bytes, response) = try await session.data(from: url)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    throw ImportError.downloadFailed((response as? HTTPURLResponse)?.statusCode)
                }
                data = bytes
                filename = response.suggestedFilename ?? url.lastPathComponent
            }
        }
        try Task.checkCancellation()
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
              let typeID = CGImageSourceGetType(imageSource),
              let type = UTType(typeID as String),
              let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            throw ImportError.invalidImage
        }
        let originalExtension = (filename as NSString).pathExtension.lowercased()
        let preferredExtension = type.preferredFilenameExtension ?? ""
        let canPreserve = MediaFile.imageExtensions.contains(preferredExtension)
        let ext = canPreserve
            ? (MediaFile.imageExtensions.contains(originalExtension) &&
               UTType(filenameExtension: originalExtension) == type ? originalExtension : preferredExtension)
            : "png"
        let output: Data
        if canPreserve {
            output = data
        } else {
            let encoded = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(encoded, UTType.png.identifier as CFString, 1, nil) else {
                throw ImportError.encodingFailed
            }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { throw ImportError.encodingFailed }
            output = encoded as Data
        }
        var stem = FilenameCleaner.filenameStem(from: (filename as NSString).deletingPathExtension)
        if stem.isEmpty || stem == "." || stem == ".." { stem = "image" }
        // withoutOverwriting also protects against a file appearing after our collision check.
        var number = 1
        while true {
            let name = number == 1 ? "\(stem).\(ext)" : "\(stem) (\(number)).\(ext)"
            let target = folder.appendingPathComponent(name)
            do {
                try output.write(to: target, options: .withoutOverwriting)
                return target
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                number += 1
            }
        }
    }

    enum ImportError: LocalizedError {
        case unsupportedURL
        case downloadFailed(Int?)
        case invalidImage
        case encodingFailed

        var errorDescription: String? {
            switch self {
            case .unsupportedURL: return "Only local files and HTTP/HTTPS image URLs can be imported."
            case .downloadFailed(let status):
                return "Image download failed\(status.map { " (HTTP \($0))" } ?? "")."
            case .invalidImage: return "The dropped content is not a readable image. Drag the image itself, not a webpage link."
            case .encodingFailed: return "The dropped image could not be converted to PNG."
            }
        }
    }
}
