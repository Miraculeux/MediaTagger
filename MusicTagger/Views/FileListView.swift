import SwiftUI

/// Middle pane: list of media files in the selected folder.
struct FileListView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Table(appState.files,
              selection: Binding(
                get: { appState.selectedFileIDs },
                set: { ids in appState.setSelection(ids) })
        ) {
            TableColumn("#") { f in
                Text(appState.tracks[f.url] ?? "")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .width(min: 50, ideal: 60, max: 90)
            TableColumn("File") { f in
                HStack {
                    Image(systemName: icon(for: f.ext))
                        .foregroundStyle(.tint)
                    Text(f.name).lineLimit(1)
                }
            }
            TableColumn("Title") { f in
                Text(appState.titles[f.url] ?? "—")
                    .foregroundStyle(appState.titles[f.url] == nil ? .secondary : .primary)
                    .lineLimit(1)
            }
        }
        .overlay {
            if appState.files.isEmpty {
                ContentUnavailableView(
                    "No media files",
                    systemImage: "music.note",
                    description: Text("Select a folder containing FLAC, MP3, M4A or other audio files.")
                )
            }
        }
    }

    private func icon(for ext: String) -> String {
        switch ext {
        case "flac", "wav", "aiff", "aif": return "waveform"
        case "mp3", "m4a", "aac", "alac":  return "music.note"
        default: return "doc"
        }
    }
}
