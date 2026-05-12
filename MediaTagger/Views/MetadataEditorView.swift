import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Right pane: property-grid style metadata editor.
struct MetadataEditorView: View {
    @EnvironmentObject var appState: AppState
    @State private var showOtherTags: Bool = false

    var body: some View {
        if appState.selectedFile == nil {
            ContentUnavailableView("No file selected",
                                   systemImage: "tag",
                                   description: Text("Pick a file from the list to view its metadata."))
        } else if let md = appState.metadata {
            editor(md)
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func editor(_ md: MediaMetadata) -> some View {
        let isImage = appState.selectedFile?.isImage == true
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let file = appState.selectedFile {
                        if isImage {
                            ImagePreview(url: file.url)
                        } else {
                            PlayerView(url: file.url)
                        }
                    }
                    if !isImage {
                        coverSection(md)
                        Divider()
                    }
                    if let tech = appState.technicalInfo {
                        TechnicalInfoSection(info: tech)
                        Divider()
                    }
                    if isImage {
                        imageStandardFieldsSection
                    } else {
                        standardFieldsSection
                    }
                    Divider()
                    otherTagsSection(md, isImage: isImage)
                }
                .padding(16)
            }
            Divider()
            footerBar
        }
    }

    /// Keys already exposed in the Standard Fields section (audio/video).
    private static let standardKeys: Set<String> = [
        "TITLE", "ARTIST", "ALBUM", "ALBUMARTIST",
        "TRACKNUMBER", "TRACKTOTAL", "DISCNUMBER", "DISCTOTAL",
        "DATE", "GENRE"
    ]

    /// Keys already exposed in the image standard-fields section.
    private static let imageStandardKeys: Set<String> = [
        "IPTC:ObjectName", "IPTC:Caption/Abstract", "IPTC:Byline",
        "TIFF:Copyright", "IPTC:CopyrightNotice",
        "TIFF:Software", "TIFF:DateTime",
        "EXIF:DateTimeOriginal", "TIFF:Make", "TIFF:Model",
        "EXIF:UserComment", "EXIF:LensModel",
        "GPS:Latitude", "GPS:LatitudeRef",
        "GPS:Longitude", "GPS:LongitudeRef",
    ]

    // MARK: Standard fields (image)

    private var imageStandardFieldsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("EXIF / IPTC Fields").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                imgRow("Title",        key: "IPTC:ObjectName")
                imgRow("Description",  key: "IPTC:Caption/Abstract")
                imgRow("Artist",       key: "IPTC:Byline")
                imgRow("Copyright",    key: "TIFF:Copyright")
                imgRow("Date Taken",   key: "EXIF:DateTimeOriginal",
                       placeholder: "YYYY:MM:DD HH:MM:SS")
                imgRow("File Date",    key: "TIFF:DateTime",
                       placeholder: "YYYY:MM:DD HH:MM:SS")
                imgRow("Camera Make",  key: "TIFF:Make")
                imgRow("Camera Model", key: "TIFF:Model")
                imgRow("Lens",         key: "EXIF:LensModel")
                imgRow("Software",     key: "TIFF:Software")
                imgRow("User Comment", key: "EXIF:UserComment")
                imgRow("GPS Lat",      key: "GPS:Latitude",
                       placeholder: "decimal degrees")
                imgRow("GPS Lon",      key: "GPS:Longitude",
                       placeholder: "decimal degrees")
            }
        }
    }

    private func imgRow(_ label: String, key: String, placeholder: String = "") -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .trailing)
            StandardField(key: key, placeholder: placeholder)
        }
    }

    // MARK: Standard fields (audio/video)

    /// Always-visible editable rows for the most common keys (including TRACKNUMBER /
    /// TRACKTOTAL / DISCNUMBER / DISCTOTAL), independent of whether they exist on the file.
    private var standardFieldsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Standard Fields").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                stdRow("Title",        key: "TITLE")
                stdRow("Artist",       key: "ARTIST")
                stdRow("Album",        key: "ALBUM")
                stdRow("Album Artist", key: "ALBUMARTIST")
                trackDiscRow
                stdRow("Date",         key: "DATE")
                stdRow("Genre",        key: "GENRE")
            }
        }
    }

    private func stdRow(_ label: String, key: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .trailing)
            StandardField(key: key)
        }
    }

    private var trackDiscRow: some View {
        GridRow {
            Text("Track")
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .trailing)
            HStack(spacing: 6) {
                StandardField(key: "TRACKNUMBER", placeholder: "#", width: 60)
                Text("/").foregroundStyle(.secondary)
                StandardField(key: "TRACKTOTAL", placeholder: "total", width: 60)
                Spacer().frame(width: 16)
                Text("Disc").foregroundStyle(.secondary)
                StandardField(key: "DISCNUMBER", placeholder: "#", width: 50)
                Text("/").foregroundStyle(.secondary)
                StandardField(key: "DISCTOTAL", placeholder: "total", width: 50)
                Spacer()
            }
        }
    }

    // MARK: Cover

    @ViewBuilder
    private func coverSection(_ md: MediaMetadata) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                if let data = md.coverArt, let img = NSImage(data: data) {
                    Image(nsImage: img)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                } else {
                    ZStack {
                        Rectangle().fill(.quaternary)
                        Image(systemName: "photo")
                            .font(.system(size: 28))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 120, height: 120)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 6) {
                Text("Cover Art").font(.headline)
                trackBadge(md)
                if let mime = md.coverMimeType { Text(mime).font(.caption).foregroundStyle(.secondary) }
                HStack {
                    Button("Replace…") { pickCover() }
                    Button("Remove", role: .destructive) {
                        var m = md; m.coverArt = nil; m.coverMimeType = nil
                        appState.metadata = m; appState.isDirty = true
                    }
                    .disabled(md.coverArt == nil)
                }
            }
            Spacer()
        }
    }

    private func pickCover() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.jpeg, .png]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) {
            var m = appState.metadata ?? MediaMetadata()
            m.coverArt = data
            m.coverMimeType = url.pathExtension.lowercased() == "png" ? "image/png" : "image/jpeg"
            appState.metadata = m
            appState.isDirty = true
        }
    }

    // MARK: Tags

    /// Compact "Track 03 / 12" badge using TRACKNUMBER (and optional TRACKTOTAL or "n/total" syntax).
    @ViewBuilder
    private func trackBadge(_ md: MediaMetadata) -> some View {
        if let display = md.trackDisplay {
            HStack(spacing: 6) {
                Image(systemName: "number")
                    .font(.caption.weight(.semibold))
                Text(display)
                    .font(.system(.callout, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                if let disc = md.discDisplay {
                    Text("·").foregroundStyle(.secondary)
                    Image(systemName: "opticaldisc")
                        .font(.caption)
                    Text(disc)
                        .font(.callout)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.accentColor.opacity(0.15), in: Capsule())
            .foregroundStyle(Color.accentColor)
        }
    }

    @ViewBuilder
    private func otherTagsSection(_ md: MediaMetadata, isImage: Bool) -> some View {
        let excluded = isImage ? Self.imageStandardKeys : Self.standardKeys
        let extras = md.tags.filter { !excluded.contains($0.key.uppercased())
                                       && !excluded.contains($0.key) }
        DisclosureGroup(isExpanded: $showOtherTags) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(extras) { tag in
                    TagRow(tag: tag)
                }
                Button {
                    appState.addTag()
                    showOtherTags = true
                } label: {
                    Label("Add custom tag", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .padding(.top, 4)
            }
            .padding(.top, 6)
        } label: {
            HStack(spacing: 6) {
                Text("Other Tags").font(.headline)
                if !extras.isEmpty {
                    Text("\(extras.count)")
                        .font(.caption.monospacedDigit())
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Footer

    private var footerBar: some View {
        HStack {
            if let err = appState.lastError {
                ErrorChip(message: err) { appState.lastError = nil }
            }
            Spacer()
            if appState.isDirty {
                Text("Unsaved changes").font(.caption).foregroundStyle(.orange)
            }
            Button("Revert") {
                if let f = appState.selectedFile { appState.selectFile(f) }
            }
            .disabled(!appState.isDirty)
            Button("Save") { appState.saveCurrent() }
                .keyboardShortcut("s", modifiers: [.command])
                .disabled(!appState.isDirty)
                .buttonStyle(.borderedProminent)
        }
        .padding(10)
    }
}

private struct TagRow: View {
    @EnvironmentObject var appState: AppState
    let tag: MediaMetadata.Tag

    @State private var key: String = ""
    @State private var value: String = ""

    var body: some View {
        HStack(spacing: 8) {
            TextField("KEY", text: $key, onCommit: commit)
                .textFieldStyle(.roundedBorder)
                .frame(width: 140)
                .font(.system(.body, design: .monospaced))
            TextField("value", text: $value, onCommit: commit)
                .textFieldStyle(.roundedBorder)
            Button(role: .destructive) {
                appState.removeTag(id: tag.id)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
        }
        .onAppear {
            key = tag.key
            value = tag.value
        }
        .onChange(of: key) { _, _ in commit() }
        .onChange(of: value) { _, _ in commit() }
    }

    private func commit() {
        // Preserve case for prefixed image tags (e.g. "EXIF:DateTimeOriginal")
        // — ImageIO expects the exact camelCase key. For audio/video tags
        // (Vorbis comments, ID3) we keep the convention of uppercasing the key.
        let normalizedKey = key.contains(":") ? key : key.uppercased()
        appState.updateTag(id: tag.id, key: normalizedKey, value: value)
    }
}

/// Read-only display of stream-level audio properties (sample rate, bit depth,
/// bitrate, duration, channels, file size). Hidden when no info is available.
private struct TechnicalInfoSection: View {
    private struct Formatted {
        let format: String?
        let sampleRate: String?
        let bitDepth: String?
        let channels: String?
        let bitrate: String?
        let duration: String?
        let fileSize: String?
        let dimensions: String?
        let colorModel: String?
        let isImage: Bool
    }

    private let f: Formatted

    init(info: MediaTechnicalInfo) {
        self.f = Self.format(info)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Info").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                if let s = f.format     { row("Format",      s) }
                if let s = f.dimensions { row("Dimensions",  s) }
                if let s = f.colorModel { row("Color",       s) }
                if !f.isImage, let s = f.sampleRate { row("Sample Rate", s) }
                if let s = f.bitDepth   { row("Bit Depth",   s) }
                if !f.isImage, let s = f.channels   { row("Channels",    s) }
                if !f.isImage, let s = f.bitrate    { row("Bitrate",     s) }
                if !f.isImage, let s = f.duration   { row("Duration",    s) }
                if let s = f.fileSize   { row("File Size",   s) }
            }
            .font(.callout.monospacedDigit())
        }
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .trailing)
            Text(value).textSelection(.enabled)
        }
    }

    // MARK: Formatting (computed once at init, cached for the view's lifetime)

    private static func format(_ info: MediaTechnicalInfo) -> Formatted {
        Formatted(
            format:     formatString(info),
            sampleRate: sampleRateString(info),
            bitDepth:   bitDepthString(info),
            channels:   channelsString(info),
            bitrate:    bitrateString(info),
            duration:   durationString(info),
            fileSize:   fileSizeString(info),
            dimensions: dimensionsString(info),
            colorModel: info.isImage ? info.colorModel : nil,
            isImage:    info.isImage
        )
    }

    private static func dimensionsString(_ info: MediaTechnicalInfo) -> String? {
        guard let w = info.pixelWidth, let h = info.pixelHeight, w > 0, h > 0 else { return nil }
        let mp = Double(w * h) / 1_000_000
        if mp >= 0.1 {
            return String(format: "%d × %d  (%.1f MP)", w, h, mp)
        }
        return "\(w) × \(h)"
    }

    private static func formatString(_ info: MediaTechnicalInfo) -> String? {
        switch (info.container, info.codec) {
        case (let c?, let k?) where c.caseInsensitiveCompare(k) != .orderedSame:
            return "\(c) (\(k))"
        case (let c?, _): return c
        case (_, let k?): return k
        default: return nil
        }
    }

    private static func sampleRateString(_ info: MediaTechnicalInfo) -> String? {
        guard let sr = info.sampleRate, sr > 0 else { return nil }
        if info.isDSD {
            // DSD rates are conventionally expressed as multiples of 44.1 kHz
            // (DSD64 = 2.8224 MHz, DSD128 = 5.6448 MHz, …).
            let mhz = sr / 1_000_000
            let multiple = Int((sr / 44_100.0).rounded())
            return String(format: "%.4f MHz (DSD%d)", mhz, multiple)
        }
        let khz = sr / 1000
        if khz.truncatingRemainder(dividingBy: 1) == 0 {
            return "\(Int(khz)) kHz"
        }
        return String(format: "%.1f kHz", khz)
    }

    private static func bitDepthString(_ info: MediaTechnicalInfo) -> String? {
        guard let b = info.bitsPerSample, b > 0 else { return nil }
        return info.isDSD ? "1-bit (DSD)" : "\(b)-bit"
    }

    private static func channelsString(_ info: MediaTechnicalInfo) -> String? {
        guard let ch = info.channels, ch > 0 else { return nil }
        switch ch {
        case 1: return "1 (Mono)"
        case 2: return "2 (Stereo)"
        default: return "\(ch)"
        }
    }

    private static func bitrateString(_ info: MediaTechnicalInfo) -> String? {
        guard let br = info.bitrate, br > 0 else { return nil }
        if br >= 1_000_000 {
            return String(format: "%.2f Mbps", br / 1_000_000)
        }
        return String(format: "%.0f kbps", br / 1000)
    }

    private static func durationString(_ info: MediaTechnicalInfo) -> String? {
        guard let d = info.durationSeconds, d.isFinite, d > 0 else { return nil }
        let total = Int(d.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    private static func fileSizeString(_ info: MediaTechnicalInfo) -> String? {
        guard let bytes = info.fileSizeBytes, bytes > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// Editable field bound to a single standard tag key on `AppState.metadata`.
/// Reads the current value when the selected file changes; writes through
/// `setStandardTag` (empty string removes the tag).
private struct StandardField: View {
    @EnvironmentObject var appState: AppState
    let key: String
    var placeholder: String = ""
    var width: CGFloat? = nil

    @State private var text: String = ""

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.roundedBorder)
            .frame(width: width)
            .onAppear { text = appState.standardTagValue(key) }
            .onChange(of: appState.selectedFile?.id) { _, _ in
                text = appState.standardTagValue(key)
            }
            // The metadata for the selected file loads asynchronously after
            // selection changes (see AppState.setSelection). When that load
            // completes and replaces `metadata`, the field must re-seed its
            // local `text` from the new value — otherwise it keeps showing
            // the previous file's tag and gets out of sync with the file
            // list (which reads from the `titles` cache).
            .onChange(of: appState.metadata) { _, _ in
                let current = appState.standardTagValue(key)
                if text != current { text = current }
            }
            .onChange(of: text) { _, newValue in
                if newValue != appState.standardTagValue(key) {
                    appState.setStandardTag(key, newValue)
                }
            }
    }
}

/// Lightweight preview for still images (selected EXIF-capable file).
private struct ImagePreview: View {
    let url: URL

    var body: some View {
        Group {
            if let img = NSImage(contentsOf: url) {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 280)
            } else {
                ZStack {
                    Rectangle().fill(.quaternary)
                    Image(systemName: "photo")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                }
                .frame(height: 200)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
