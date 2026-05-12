import SwiftUI
import AppKit

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

    /// Copy the first selected file's title to the clipboard. Falls back to
    /// the filename without its extension when no title metadata is present.
    private func copySelectedTitle() {
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
