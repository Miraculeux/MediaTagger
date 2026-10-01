import SwiftUI
import AppKit

struct FileListRow: Identifiable, Equatable {
    let file: MediaFile
    let title: String?
    let track: String

    var id: URL { file.id }
    var fileSortValue: String { file.name }
    var titleSortValue: String { title ?? "" }
    var trackSortValue: String {
        String(track.prefix { $0 != "/" }).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func orderedBefore(_ other: FileListRow, by field: FileListSortField, ascending: Bool) -> Bool {
        var result: ComparisonResult
        switch field {
        case .file:
            result = fileSortValue.localizedStandardCompare(other.fileSortValue)
        case .title:
            result = titleSortValue.localizedStandardCompare(other.titleSortValue)
        case .track:
            result = trackSortValue.compare(other.trackSortValue, options: [.numeric, .caseInsensitive])
        }
        if result == .orderedSame {
            result = fileSortValue.localizedStandardCompare(other.fileSortValue)
        }
        if result == .orderedSame {
            result = id.path.compare(other.id.path)
        }
        return ascending ? result == .orderedAscending : result == .orderedDescending
    }
}

enum FileListSortField: String {
    case file
    case title
    case track
}

/// Middle pane: list of media files in the selected folder.
struct FileListView: View {
    @EnvironmentObject var appState: AppState
    @State private var sortField: FileListSortField = .track
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
        rows.sorted { $0.orderedBefore($1, by: sortField, ascending: sortAscending) }
    }

    var body: some View {
        VStack(spacing: 0) {
            NativeFileTableView(
                rows: sortedRows,
                selection: Binding(
                    get: { appState.selectedFileIDs },
                    set: { appState.setSelection($0) }
                ),
                icon: icon,
                menuEntries: { targets in
                    [
                        .item(title: "Reveal in Finder", enabled: !targets.isEmpty) { revealInFinder(targets) },
                        .item(title: "Reveal in Seeker", enabled: !targets.isEmpty) { revealInSeeker(targets) },
                        .separator,
                        .item(title: "Refresh", enabled: true) { appState.refreshFiles() }
                    ]
                },
                onSortChanged: { field, ascending in
                    sortField = field
                    sortAscending = ascending
                },
                sortField: sortField,
                sortAscending: sortAscending
            )
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
