import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Right pane shown when more than one file is selected.
/// Lets the user toggle batch operations and apply them to the selection.
struct BatchEditorView: View {
    @EnvironmentObject var appState: AppState

    // Operation toggles
    @State private var setTitleFromFilename = false
    @State private var cleanup = FilenameCleanupOptions()

    @State private var setAlbum = false;       @State private var album = ""
    @State private var setAlbumArtist = false; @State private var albumArtist = ""
    @State private var setArtist = false;      @State private var artist = ""
    @State private var setDate = false;        @State private var date = ""
    @State private var setGenre = false;       @State private var genre = ""
    @State private var setDiscNumber = false;  @State private var discNumber = "1"
    @State private var setDiscTotal = false;   @State private var discTotal = "1"

    @State private var renumber = false
    @State private var startAt = 1
    @State private var writeTrackTotal = true
    @State private var padWidth = 2

    @State private var coverData: Data?
    @State private var coverMime: String?
    @State private var clearCover = false

    /// True while we're programmatically writing field values; suppresses
    /// the "start typing -> auto-enable checkbox" behavior in `toggledField`.
    @State private var isPrefilling = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    titleSection
                    Divider()
                    albumSection
                    Divider()
                    discTrackSection
                    Divider()
                    coverSection
                }
                .padding(16)
            }
            Divider()
            footer
        }
        .onAppear { prefillFromFirstFile() }
        .onChange(of: appState.selectedFileIDs) { _, _ in prefillFromFirstFile() }
    }

    /// Pre-populate field text (and cover preview) using the first selected file's
    /// existing tags so the user can edit common values starting from a real baseline.
    /// Toggles are left OFF — user must explicitly opt-in to apply each one.
    private func prefillFromFirstFile() {
        guard let first = appState.selectedFiles.first,
              let md = try? MetadataService().read(first.url) else { return }
        isPrefilling = true
        defer {
            // Drop the suppression flag on the next runloop tick, after the
            // text-binding onChange handlers have fired.
            DispatchQueue.main.async { isPrefilling = false }
        }
        if let v = md.first("ALBUM")       { album = v }
        if let v = md.first("ALBUMARTIST") { albumArtist = v }
        if let v = md.first("ARTIST")      { artist = v }
        if let v = md.first("DATE")        { date = v }
        if let v = md.first("GENRE")       { genre = v }
        if let v = md.first("DISCNUMBER")  { discNumber = v }
        if let v = md.first("DISCTOTAL")   { discTotal = v }
        if let data = md.coverArt {
            coverData = data
            coverMime = md.coverMimeType
            clearCover = false
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.stack.3d.up")
            Text("\(appState.selectedFileIDs.count) files selected")
                .font(.headline)
            Spacer()
        }
        .padding(12)
    }

    // MARK: Sections

    private var titleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Set TITLE from filename", isOn: $setTitleFromFilename)
                .font(.headline)
            if setTitleFromFilename {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Strip leading track number", isOn: $cleanup.stripLeadingTrackNumber)
                    Toggle("Replace underscores with spaces", isOn: $cleanup.underscoresToSpaces)
                    Toggle("Collapse whitespace", isOn: $cleanup.collapseWhitespace)
                    Toggle("Trim", isOn: $cleanup.trim)
                }
                .padding(.leading, 20)
                preview
            }
        }
    }

    private var preview: some View {
        let sample = appState.selectedFiles.prefix(3)
        return VStack(alignment: .leading, spacing: 2) {
            Text("Preview").font(.caption).foregroundStyle(.secondary)
            ForEach(Array(sample), id: \.id) { f in
                HStack {
                    Text(f.name).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                    Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.secondary)
                    Text(FilenameCleaner.title(from: f.name, options: cleanup))
                        .font(.caption).lineLimit(1)
                }
            }
            if appState.selectedFiles.count > sample.count {
                Text("…and \(appState.selectedFiles.count - sample.count) more")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 20)
    }

    @ViewBuilder
    private var albumSection: some View {
        Text("Common tags").font(.headline)
        toggledField("ALBUM",       on: $setAlbum,       text: $album)
        toggledField("ALBUMARTIST", on: $setAlbumArtist, text: $albumArtist)
        toggledField("ARTIST",      on: $setArtist,      text: $artist)
        toggledField("DATE",        on: $setDate,        text: $date)
        toggledField("GENRE",       on: $setGenre,       text: $genre)
    }

    @ViewBuilder
    private var discTrackSection: some View {
        Text("Disc & track").font(.headline)
        toggledField("DISCNUMBER", on: $setDiscNumber, text: $discNumber)
        toggledField("DISCTOTAL",  on: $setDiscTotal,  text: $discTotal)

        Toggle("Renumber TRACKNUMBER from selection order", isOn: $renumber)
        if renumber {
            HStack {
                Stepper("Start at \(startAt)", value: $startAt, in: 1...999)
                    .frame(maxWidth: 180, alignment: .leading)
                Stepper("Pad width \(padWidth)", value: $padWidth, in: 0...4)
                    .frame(maxWidth: 180, alignment: .leading)
                Toggle("Write TRACKTOTAL", isOn: $writeTrackTotal)
            }
            .padding(.leading, 20)
        }
    }

    @ViewBuilder
    private var coverSection: some View {
        Text("Cover art").font(.headline)
        HStack(alignment: .top, spacing: 12) {
            Group {
                if let d = coverData, let img = NSImage(data: d) {
                    Image(nsImage: img).resizable().scaledToFit()
                } else {
                    ZStack {
                        Rectangle().fill(.quaternary)
                        Image(systemName: clearCover ? "trash" : "photo")
                            .font(.system(size: 24)).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 96, height: 96)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 6) {
                Button("Choose cover…") { pickCover() }
                Button("Clear cover on all files", role: .destructive) {
                    coverData = nil; coverMime = nil; clearCover = true
                }
                if coverData != nil || clearCover {
                    Button("Reset (don't change)") {
                        coverData = nil; coverMime = nil; clearCover = false
                    }
                }
            }
            Spacer()
        }
    }

    private func pickCover() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.jpeg, .png]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK,
           let url = panel.url,
           let d = try? Data(contentsOf: url) {
            coverData = d
            coverMime = url.pathExtension.lowercased() == "png" ? "image/png" : "image/jpeg"
            clearCover = false
        }
    }

    @ViewBuilder
    private func toggledField(_ label: String, on: Binding<Bool>, text: Binding<String>) -> some View {
        HStack(spacing: 8) {
            Toggle(isOn: on) {
                Text(label)
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 110, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .toggleStyle(.checkbox)
            TextField(label.lowercased(), text: text)
                .textFieldStyle(.roundedBorder)
                .opacity(on.wrappedValue ? 1.0 : 0.6)
                // Enable the operation as soon as the user types or focuses this field.
                .onChange(of: text.wrappedValue) { _, newValue in
                    if !isPrefilling, !newValue.isEmpty, !on.wrappedValue {
                        on.wrappedValue = true
                    }
                }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            if appState.batchInProgress {
                ProgressView(value: appState.batchProgress).frame(width: 160)
            }
            if let err = appState.lastError {
                ErrorChip(message: err) { appState.lastError = nil }
            }
            Spacer()
            Button("Apply to \(appState.selectedFileIDs.count) files") {
                apply()
            }
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(!hasOps || appState.batchInProgress)
            .buttonStyle(.borderedProminent)
        }
        .padding(10)
    }

    private var hasOps: Bool { buildPlan().hasAnyOperation }

    private func buildPlan() -> BatchPlan {
        var p = BatchPlan()
        if setTitleFromFilename { p.titleFromFilename = cleanup }
        if setAlbum { p.album = album }
        if setAlbumArtist { p.albumArtist = albumArtist }
        if setArtist { p.artist = artist }
        if setDate { p.date = date }
        if setGenre { p.genre = genre }
        if setDiscNumber { p.discNumber = discNumber }
        if setDiscTotal { p.discTotal = discTotal }
        if renumber {
            p.renumberTracks = TrackNumberingOptions(
                startAt: startAt, writeTotal: writeTrackTotal, zeroPadWidth: padWidth)
        }
        if let d = coverData {
            p.coverArt = d
            p.coverMime = coverMime
        } else if clearCover {
            p.clearCoverArt = true
        }
        return p
    }

    private func apply() {
        appState.applyBatch(buildPlan())
    }
}
