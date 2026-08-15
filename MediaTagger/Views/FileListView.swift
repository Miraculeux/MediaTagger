import SwiftUI
import AppKit

private struct FileListRow: Identifiable {
    let file: MediaFile
    let title: String?
    let track: String

    var id: URL { file.id }
    var fileSortValue: String { file.name }
    var titleSortValue: String { title ?? "" }
}

private struct FileListDisplayRow: Identifiable {
    let id: Int
    let value: FileListRow
}

private enum FileListSortField {
    case file
    case title
}

/// Middle pane: list of media files in the selected folder.
struct FileListView: View {
    @EnvironmentObject var appState: AppState
    @State private var sortField: FileListSortField = .file
    @State private var sortAscending = true

    private var rows: [FileListRow] {
        appState.files.map { file in
            FileListRow(
                file: file,
                title: appState.titles[file.url],
                track: appState.tracks[file.url] ?? ""
            )
        }
    }

    private var sortedRows: [FileListRow] {
        rows.sorted { lhs, rhs in
            var result: ComparisonResult
            switch sortField {
            case .file:
                result = lhs.fileSortValue.localizedStandardCompare(rhs.fileSortValue)
            case .title:
                result = lhs.titleSortValue.localizedStandardCompare(rhs.titleSortValue)
                if result == .orderedSame {
                    result = lhs.fileSortValue.localizedStandardCompare(rhs.fileSortValue)
                }
            }
            if result == .orderedSame {
                result = lhs.id.path.compare(rhs.id.path)
            }
            return sortAscending ? result == .orderedAscending : result == .orderedDescending
        }
    }

    private var displayRows: [FileListDisplayRow] {
        sortedRows.enumerated().map { FileListDisplayRow(id: $0.offset, value: $0.element) }
    }

    private var displaySelection: Binding<Set<Int>> {
        Binding(
            get: {
                Set(displayRows.compactMap { row in
                    appState.selectedFileIDs.contains(row.value.id) ? row.id : nil
                })
            },
            set: { positions in
                let fileIDs = Set(displayRows.compactMap { row in
                    positions.contains(row.id) ? row.value.id : nil
                })
                appState.setSelection(fileIDs)
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            tableHeader
            Divider()
                Table(displayRows, selection: displaySelection) {
                TableColumn("#") { row in
                    Text(row.value.track)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .width(min: 50, ideal: 60, max: 90)
                TableColumn("File") { row in
                    HStack {
                        Image(systemName: icon(for: row.value.file.ext))
                            .foregroundStyle(.tint)
                        Text(row.value.file.name).lineLimit(1)
                    }
                }
                TableColumn("Title") { row in
                    Text(row.value.title ?? "—")
                        .foregroundStyle(row.value.title == nil ? .secondary : .primary)
                        .lineLimit(1)
                }
            }
            .tableColumnHeaders(.hidden)
            .contextMenu(forSelectionType: Int.self) { positions in
                // Right-click on a row: ensure the clicked row participates in
                // the action even if it wasn't already selected.
                let targets = positions.isEmpty
                    ? appState.selectedFileIDs
                    : Set(displayRows.compactMap { row in
                        positions.contains(row.id) ? row.value.id : nil
                    })
                Button("Reveal in Finder") { revealInFinder(targets) }
                    .disabled(targets.isEmpty)
                Button("Reveal in Seeker") { revealInSeeker(targets) }
                    .disabled(targets.isEmpty)
                Divider()
                Button("Refresh") { appState.refreshFiles() }
            }
            .background {
                // Hidden ⌘C handler: copies the selected file's title (or its
                // filename without extension if no title is known). Disabled when
                // nothing is selected so the shortcut falls through to the system.
                Button("Copy", action: copySelectedTitle)
                    .keyboardShortcut("c", modifiers: .command)
                    .disabled(appState.selectedFileIDs.isEmpty)
                    .opacity(0)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
            .overlay {
                if appState.files.isEmpty {
                    ContentUnavailableView(
                        "No media files",
                        systemImage: "play.rectangle",
                        description: Text("Select a folder containing audio (FLAC, MP3, M4A, AIFF, MKA, OGG, …), video (MP4, MOV, MKV, …) or image (JPEG, TIFF, HEIC, PNG) files.")
                    )
                }
            }
        }
    }

    private var tableHeader: some View {
        HStack(spacing: 0) {
            Text("#")
                .padding(.leading, 8)
                .frame(width: 60, alignment: .leading)
            Divider()
            sortButton("File", field: .file)
            Divider()
            sortButton("Title", field: .title)
        }
        .frame(height: 28)
        .background(Color(nsColor: .controlBackgroundColor))
        .font(.callout)
    }

    private func sortButton(_ title: String, field: FileListSortField) -> some View {
        Button {
            if sortField == field {
                sortAscending.toggle()
            } else {
                sortField = field
                sortAscending = true
            }
        } label: {
            HStack(spacing: 5) {
                Text(title)
                if sortField == field {
                    Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Show the given file URLs in Finder. When multiple URLs share a parent
    /// (the common case) Finder opens one window with all of them highlighted.
    private func revealInFinder(_ ids: Set<URL>) {
        let urls = appState.files
            .filter { ids.contains($0.id) }
            .map(\.url)
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    /// Open the first selected file in the Seeker app via its `seeker://reveal`
    /// URL scheme. Seeker can only focus one path at a time so we use the
    /// first selection if multiple rows are selected.
    private func revealInSeeker(_ ids: Set<URL>) {
        guard let url = appState.files.first(where: { ids.contains($0.id) })?.url else { return }
        var comps = URLComponents()
        comps.scheme = "seeker"
        comps.host = "reveal"
        comps.queryItems = [URLQueryItem(name: "path", value: url.path)]
        guard let target = comps.url else { return }
        NSWorkspace.shared.open(target)
    }

    /// Copy the first selected file's title to the clipboard. Falls back to
    /// the filename without its extension when no title metadata is present.
    private func copySelectedTitle() {
        // Try the responder chain first: if a text field / text view has
        // focus, its own copy: handler runs and we're done. sendAction
        // returns false only when nothing in the chain implements copy:,
        // in which case we fall through to the file-list copy below.
        if NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil) {
            return
        }
        guard let file = appState.files.first(where: {
            appState.selectedFileIDs.contains($0.id)
        }) else { return }
        let title = appState.titles[file.url]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = (title?.isEmpty == false ? title! : file.url.deletingPathExtension().lastPathComponent)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    private func icon(for ext: String) -> String {
        switch ext {
        case "flac", "wav", "aiff", "aif", "aifc":
            return "waveform"
        case "mp3", "m4a", "m4b", "aac", "alac", "ogg", "opus", "mka":
            return "music.note"
        case "mp4", "m4v", "mov", "mkv", "webm", "avi":
            return "film"
        case "jpg", "jpeg", "tif", "tiff", "heic", "heif", "png", "gif":
            return "photo"
        default: return "doc"
        }
    }
}
