import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Right pane: property-grid style metadata editor.
struct MetadataEditorView: View {
    @EnvironmentObject var appState: AppState

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
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    coverSection(md)
                    Divider()
                    standardFieldsSection
                    Divider()
                    tagsSection(md)
                }
                .padding(16)
            }
            Divider()
            footerBar
        }
    }

    // MARK: Standard fields

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
    private func tagsSection(_ md: MediaMetadata) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Tags").font(.headline)
                Spacer()
                Button { appState.addTag() } label: {
                    Label("Add", systemImage: "plus")
                }
                .buttonStyle(.borderless)
            }
            ForEach(md.tags) { tag in
                TagRow(tag: tag)
            }
        }
    }

    // MARK: Footer

    private var footerBar: some View {
        HStack {
            if let err = appState.lastError {
                Text(err).font(.caption).foregroundStyle(.red).lineLimit(2)
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
        appState.updateTag(id: tag.id, key: key.uppercased(), value: value)
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
            .onChange(of: text) { _, newValue in
                if newValue != appState.standardTagValue(key) {
                    appState.setStandardTag(key, newValue)
                }
            }
    }
}
