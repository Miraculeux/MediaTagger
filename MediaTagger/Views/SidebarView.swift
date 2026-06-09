import SwiftUI

/// Left pane: hierarchical folder navigator rooted at `appState.rootURL`.
struct SidebarView: View {
    @EnvironmentObject var appState: AppState

    /// Root of the folder tree. Held in `@State` so the cached `FolderNode`
    /// instances (and the `[FolderNode]?` they memoise from
    /// `contentsOfDirectory`) survive across SidebarView body re-evaluations.
    /// Without this the tree would be rebuilt — and every visible folder's
    /// children rescanned — on every unrelated state change.
    @State private var rootNode: FolderNode?
    @State private var searchText: String = ""

    var body: some View {
        Group {
            if let root = appState.rootURL, let node = rootNode {
                VStack(spacing: 0) {
                    toolbar
                    Divider()
                    if searchText.isEmpty {
                        List(selection: Binding(
                            get: { appState.selectedFolder },
                            set: { if let url = $0 { appState.loadFiles(in: url) } }
                        )) {
                            OutlineGroup(node, children: \.children) { node in
                                Label(node.url.lastPathComponent, systemImage: "folder")
                                    .tag(node.url)
                            }
                        }
                        .listStyle(.sidebar)
                        .id(root)
                    } else {
                        searchResults(in: node)
                    }
                }
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
        .onAppear(perform: syncRoot)
        .onChange(of: appState.rootURL) { _, _ in syncRoot() }
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search folders", text: $searchText)
                .textFieldStyle(.roundedBorder)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
            Button(action: refresh) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh folder tree")
            .keyboardShortcut("r", modifiers: [.command])
        }
        .padding(8)
    }

    @ViewBuilder
    private func searchResults(in root: FolderNode) -> some View {
        let matches = collectMatches(root: root, query: searchText, limit: 500)
        if matches.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "folder.badge.questionmark")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("No folders match")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(selection: Binding(
                get: { appState.selectedFolder },
                set: { if let url = $0 { appState.loadFiles(in: url) } }
            )) {
                ForEach(matches, id: \.url) { node in
                    VStack(alignment: .leading, spacing: 1) {
                        Label(node.url.lastPathComponent, systemImage: "folder")
                        if let rootURL = appState.rootURL,
                           let relative = relativePath(of: node.url, root: rootURL) {
                            Text(relative)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .tag(node.url)
                }
            }
            .listStyle(.sidebar)
        }
    }

    /// Force a full re-scan of the folder tree and the currently selected folder.
    private func refresh() {
        if let url = appState.rootURL {
            rootNode = FolderNode(url: url)
        }
        appState.refreshFiles()
    }

    /// BFS the folder tree collecting nodes whose name contains `query`
    /// (case-insensitive). Capped to keep the UI responsive on large libraries.
    private func collectMatches(root: FolderNode, query: String, limit: Int) -> [FolderNode] {
        let needle = query.lowercased()
        var results: [FolderNode] = []
        var queue: [FolderNode] = [root]
        while !queue.isEmpty, results.count < limit {
            let node = queue.removeFirst()
            if node.url != root.url,
               node.url.lastPathComponent.lowercased().contains(needle) {
                results.append(node)
            }
            if let children = node.children {
                queue.append(contentsOf: children)
            }
        }
        return results
    }

    private func relativePath(of url: URL, root: URL) -> String? {
        let rootPath = root.path
        let p = url.path
        guard p.hasPrefix(rootPath) else { return nil }
        var rel = String(p.dropFirst(rootPath.count))
        if rel.hasPrefix("/") { rel.removeFirst() }
        return rel.isEmpty ? nil : rel
    }

    /// Rebuild the root node (discarding the entire children cache) only when
    /// the user picks a different root folder.
    private func syncRoot() {
        if let url = appState.rootURL {
            if rootNode?.url != url { rootNode = FolderNode(url: url) }
        } else {
            rootNode = nil
        }
    }
}

/// Lightweight, lazily-loaded folder tree node.
///
/// Reference type so the per-node `children` cache survives across SwiftUI
/// view rebuilds. `OutlineGroup` calls `\.children` repeatedly while the
/// sidebar redraws (selection changes, focus changes, batch progress
/// updates, …); without caching, each access re-runs `contentsOfDirectory`
/// — measurable overhead for large music libraries with deep folder trees
/// or those served from network volumes.
final class FolderNode: Identifiable, Hashable {
    let url: URL
    var id: URL { url }

    /// `nil` while we haven't scanned yet; `.some(nil)` after scanning a
    /// childless / unreadable directory; `.some([...])` after a successful
    /// scan. SwiftUI evaluates view bodies on the main actor, so the
    /// non-atomic cache is safe without locking.
    private var didScan = false
    private var cachedChildren: [FolderNode]?

    init(url: URL) { self.url = url }

    var children: [FolderNode]? {
        if !didScan {
            cachedChildren = Self.scan(url)
            didScan = true
        }
        return cachedChildren
    }

    static func == (lhs: FolderNode, rhs: FolderNode) -> Bool { lhs.url == rhs.url }
    func hash(into hasher: inout Hasher) { hasher.combine(url) }

    private static func scan(_ url: URL) -> [FolderNode]? {
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
