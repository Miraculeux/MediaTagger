import SwiftUI

/// Left pane: hierarchical folder navigator rooted at `appState.rootURL`.
struct SidebarView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Group {
            if let root = appState.rootURL {
                List(selection: Binding(
                    get: { appState.selectedFolder },
                    set: { if let url = $0 { appState.loadFiles(in: url) } }
                )) {
                    OutlineGroup(FolderNode(url: root), children: \.children) { node in
                        Label(node.url.lastPathComponent, systemImage: "folder")
                            .tag(node.url)
                    }
                }
                .listStyle(.sidebar)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text("No folder chosen")
                        .foregroundStyle(.secondary)
                    Button("Choose Root Folder…") { appState.pickRootFolder() }
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            }
        }
    }
}

/// Lightweight, lazily-loaded folder tree node.
struct FolderNode: Identifiable, Hashable {
    let url: URL
    var id: URL { url }

    var children: [FolderNode]? {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        let dirs = items
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        return dirs.isEmpty ? nil : dirs.map { FolderNode(url: $0) }
    }
}
