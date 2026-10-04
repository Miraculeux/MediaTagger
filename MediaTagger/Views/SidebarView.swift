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
    @State private var showAdvancedSearch: Bool = false
    @State private var advAlbum: String = ""
    @State private var advArtist: String = ""
    @State private var advTitle: String = ""
    @FocusState private var advFocus: AdvancedSearchField?
    private enum AdvancedSearchField { case album, artist, title }

    var body: some View {
        Group {
            if let root = appState.rootURL, let node = rootNode {
                VStack(spacing: 0) {
                    toolbar
                    if showAdvancedSearch {
                        Divider()
                        advancedSearchPanel
                    }
                    Divider()
                    if let hits = appState.advancedSearchHits {
                        advancedSearchResults(hits: hits)
                    } else if let hits = appState.coverlessFolders {
                        coverlessResults(hits: hits)
                    } else if searchText.isEmpty {
                        folderTree(node)
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

    private func folderTree(_ root: FolderNode) -> some View {
        NativeFolderTreeView(
            root: root,
            selection: Binding(
                get: { appState.selectedFolder },
                set: { if let url = $0 { appState.loadFiles(in: url) } }
            ),
            menuEntries: folderMenuEntries
        )
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
            Button {
                showAdvancedSearch.toggle()
                if showAdvancedSearch {
                    DispatchQueue.main.async { advFocus = .album }
                }
            } label: {
                Image(systemName: showAdvancedSearch
                      ? "line.3.horizontal.decrease.circle.fill"
                      : "line.3.horizontal.decrease.circle")
            }
            .buttonStyle(.borderless)
            .help("Advanced search (album / artist / title)")
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .disabled(appState.rootURL == nil)
            Button(action: refresh) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh folder tree")
            .keyboardShortcut("r", modifiers: [.command])
        }
        .padding(8)
    }

    /// Inline advanced-search panel, shown immediately under the toolbar
    /// when the filter button is toggled on. Three optional fields
    /// (Album / Artist / Title) AND together; Return submits, Escape
    /// hides the panel. Replaces the previous modal sheet so the user
    /// keeps full visibility of the sidebar while iterating on queries.
    @ViewBuilder
    private var advancedSearchPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            advField("Album",  text: $advAlbum,  field: .album)
            advField("Artist", text: $advArtist, field: .artist)
            advField("Title",  text: $advTitle,  field: .title)
            HStack(spacing: 6) {
                Spacer()
                Button("Clear") {
                    advAlbum = ""; advArtist = ""; advTitle = ""
                }
                .controlSize(.small)
                .disabled(advAlbum.isEmpty && advArtist.isEmpty && advTitle.isEmpty)
                Button("Search") { runAdvancedSearch() }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canRunAdvancedSearch)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.4))
    }

    @ViewBuilder
    private func advField(_ label: String,
                          text: Binding<String>,
                          field: AdvancedSearchField) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
            TextField("", text: text)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .focused($advFocus, equals: field)
                .onSubmit(runAdvancedSearch)
        }
    }

    private var canRunAdvancedSearch: Bool {
        appState.rootURL != nil
            && !appState.batchInProgress
            && !(advAlbum.isEmpty && advArtist.isEmpty && advTitle.isEmpty)
    }

    private func runAdvancedSearch() {
        guard canRunAdvancedSearch, let root = appState.rootURL else { return }
        appState.runAdvancedSearch(under: root,
                                   album: advAlbum,
                                   artist: advArtist,
                                   title: advTitle)
    }

    @ViewBuilder
    private func searchResults(in root: FolderNode) -> some View {
        let matches = root.matchingRoots(query: searchText, limit: 500)
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
            NativeFolderTreeView(
                root: root,
                selection: Binding(
                    get: { appState.selectedFolder },
                    set: { if let url = $0 { appState.loadFiles(in: url) } }
                ),
                menuEntries: folderMenuEntries,
                filteredRoots: matches,
                relativePathRoot: appState.rootURL
            )
        }
    }

    /// "Folders without cover" scan-result list. Shown above the folder tree
    /// after the user runs the context-menu action. The user can click any
    /// row to navigate into that folder (selecting it loads its files into
    /// the middle pane just like a normal tree click), right-click for the
    /// usual folder actions, or dismiss the entire list with the ✕ button.
    @ViewBuilder
    private func coverlessResults(hits: [URL]) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "photo.badge.exclamationmark")
                    .foregroundStyle(.orange)
                Text("\(hits.count) folder\(hits.count == 1 ? "" : "s") without cover")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    appState.clearCoverlessFolders()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close scan results")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()
            if hits.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.title2)
                        .foregroundStyle(.green)
                    Text("Every folder has a cover")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: Binding(
                    get: { appState.selectedFolder },
                    set: { if let url = $0 { appState.loadFiles(in: url) } }
                )) {
                    ForEach(hits, id: \.self) { url in
                        VStack(alignment: .leading, spacing: 1) {
                            Label(url.lastPathComponent, systemImage: "folder")
                            if let scanRoot = appState.coverlessScanRoot,
                               let relative = relativePath(of: url, root: scanRoot) {
                                Text(relative)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        .tag(url)
                        .contextMenu { folderContextMenu(for: url) }
                    }
                }
                .listStyle(.sidebar)
            }
        }
    }

    /// Force a full re-scan of the folder tree and the currently selected folder.
    private func refresh() {
        // Refresh button also dismisses any stale scan-results panel.
        appState.clearCoverlessFolders()
        appState.clearAdvancedSearch()
        if let url = appState.rootURL {
            rootNode = FolderNode(url: url)
        }
        appState.refreshFiles()
    }

    /// Advanced (metadata) search result list. Rows show track title /
    /// artist / album; clicking navigates into the containing folder and
    /// selects the file in the middle pane. The header reports the criteria
    /// the scan was run with so the user remembers what they asked for.
    @ViewBuilder
    private func advancedSearchResults(hits: [AppState.AdvancedSearchHit]) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(hits.count) match\(hits.count == 1 ? "" : "es")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !appState.advancedSearchSummary.isEmpty {
                        Text(appState.advancedSearchSummary)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                Spacer()
                Button {
                    appState.clearAdvancedSearch()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close search results")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()
            if hits.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("No matches")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: Binding<URL?>(
                    get: { appState.selectedFile?.url },
                    set: {
                        guard let url = $0,
                              let hit = hits.first(where: { $0.url == url })
                        else { return }
                        appState.openSearchHit(hit)
                    }
                )) {
                    ForEach(hits) { hit in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(hit.title ?? hit.url.deletingPathExtension().lastPathComponent)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            HStack(spacing: 4) {
                                if let artist = hit.artist, !artist.isEmpty {
                                    Text(artist)
                                }
                                if (hit.artist?.isEmpty == false) && (hit.album?.isEmpty == false) {
                                    Text("·")
                                }
                                if let album = hit.album, !album.isEmpty {
                                    Text(album)
                                }
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        }
                        .tag(hit.url)
                        .contextMenu {
                            Button("Reveal in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([hit.url])
                            }
                            Button("Reveal in Seeker") {
                                revealInSeeker(hit.url)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
            }
        }
    }

    private func relativePath(of url: URL, root: URL) -> String? {
        FolderNode.relativePath(of: url, root: root)
    }

    /// Rebuild the root node (discarding the entire children cache) only when
    /// the user picks a different root folder.
    private func syncRoot() {
        if let url = appState.rootURL {
            if rootNode?.url != url {
                rootNode = FolderNode(url: url)
                appState.clearCoverlessFolders()
                appState.clearAdvancedSearch()
            }
        } else {
            rootNode = nil
            appState.clearCoverlessFolders()
            appState.clearAdvancedSearch()
        }
    }

    /// Right-click menu shared by the folder-tree rows and the search-result
    /// rows. Reveals folder commands that don't fit on the toolbar.
    @ViewBuilder
    private func folderContextMenu(for url: URL) -> some View {
        let entries = folderMenuEntries(for: url)
        ForEach(entries.indices, id: \.self) { index in
            switch entries[index] {
            case .separator:
                Divider()
            case .item(let title, let enabled, let action):
                Button(title, action: action).disabled(!enabled)
            }
        }
    }

    private func folderMenuEntries(for url: URL) -> [BrowserMenuEntry] {
        [
            .item(title: "Reveal in Finder", enabled: true) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            },
            .item(title: "Reveal in Seeker", enabled: true) { revealInSeeker(url) },
            .separator,
            .item(title: "Find Folders Without Cover…", enabled: !appState.batchInProgress) {
                appState.findCoverlessFolders(under: url)
            },
            .item(title: "Auto-repair Covers in Subfolders…", enabled: !appState.batchInProgress) {
                confirmAndRepairCovers(under: url)
            },
            .item(title: "Normalize Embedded Covers in Subfolders…", enabled: !appState.batchInProgress) {
                confirmAndNormalizeCovers(under: url)
            }
        ]
    }

    /// Open the folder in the Seeker app via its `seeker://reveal` URL
    /// scheme. Mirrors the file-list row's "Reveal in Seeker" action so
    /// folder browsing has the same shortcut.
    private func revealInSeeker(_ url: URL) {
        var comps = URLComponents()
        comps.scheme = "seeker"
        comps.host = "reveal"
        comps.queryItems = [URLQueryItem(name: "path", value: url.path)]
        guard let target = comps.url else { return }
        NSWorkspace.shared.open(target)
    }

    /// Show a small confirmation alert (the operation rewrites tag chunks
    /// across potentially many files) and kick off the recursive repair.
    private func confirmAndRepairCovers(under url: URL) {
        let alert = NSAlert()
        alert.messageText = "Auto-repair covers in \"\(url.lastPathComponent)\"?"
        alert.informativeText = """
            Recursively scans every subfolder. In each folder that contains \
            music files, if the first track is missing a cover, an image is \
            picked (cover.* → front.* → folder-named image → first image) \
            and embedded into all files in that folder.
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Repair")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            appState.autoRepairCovers(under: url)
        }
    }

    /// Confirmation + kick-off for the Sony-compatibility pass: re-encodes
    /// existing embedded covers that don't fit the format profile (JPEG,
    /// <= 1500 px, <= 600 KB) so Sony Walkman / Hi-Res Player apps display
    /// them.
    private func confirmAndNormalizeCovers(under url: URL) {
        let alert = NSAlert()
        alert.messageText = "Normalize embedded covers in \"\(url.lastPathComponent)\"?"
        alert.informativeText = """
            Recursively scans every subfolder. In each folder, if the first \
            track's embedded cover isn't JPEG, is larger than 1500 px, or \
            exceeds 600 KB, it's re-encoded to a 1200 px JPEG (~200 KB) and \
            rewritten to every file in the folder. Folders without an \
            embedded cover or with an already-conforming one are skipped.
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Normalize")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            appState.normalizeEmbeddedCovers(under: url)
        }
    }
}

struct FolderTreeNavigation {
    struct Row: Identifiable {
        let node: FolderNode
        let depth: Int
        let parent: URL?
        var id: URL { node.url }
    }

    var expandedURLs: Set<URL> = []

    func moveVertically(root: FolderNode, selection: URL?, offset: Int) -> URL? {
        moveVertically(roots: [root], selection: selection, offset: offset)
    }

    func moveVertically(roots: [FolderNode], selection: URL?, offset: Int) -> URL? {
        let rows = visibleRows(roots: roots)
        guard let index = rows.firstIndex(where: { $0.id == selection }) else {
            return offset > 0 ? rows.first?.id : rows.last?.id
        }
        return rows[min(max(index + offset, 0), rows.count - 1)].id
    }

    func visibleRows(root: FolderNode) -> [Row] {
        visibleRows(roots: [root])
    }

    func visibleRows(roots: [FolderNode]) -> [Row] {
        func rows(_ node: FolderNode, depth: Int, parent: URL?) -> [Row] {
            var result = [Row(node: node, depth: depth, parent: parent)]
            if expandedURLs.contains(node.url), let children = node.children {
                for child in children {
                    result.append(contentsOf: rows(child, depth: depth + 1, parent: node.url))
                }
            }
            return result
        }
        return roots.flatMap { rows($0, depth: 0, parent: nil) }
    }

    mutating func moveHorizontally(root: FolderNode, selection: URL?, expanding: Bool) -> URL? {
        moveHorizontally(roots: [root], selection: selection, expanding: expanding)
    }

    mutating func moveHorizontally(roots: [FolderNode], selection: URL?, expanding: Bool) -> URL? {
        guard let row = visibleRows(roots: roots).first(where: { $0.id == selection }) else {
            return roots.first?.url
        }
        if expanding {
            guard let children = row.node.children else { return row.id }
            if expandedURLs.insert(row.id).inserted { return row.id }
            return children.first?.url
        }
        if expandedURLs.remove(row.id) != nil { return row.id }
        return row.parent ?? row.id
    }
}

/// Lightweight, lazily-loaded folder tree node.
///
/// Reference type so the per-node `children` cache survives across SwiftUI
/// view rebuilds. The folder tree reads `children` repeatedly while the
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

    /// Matching ancestors own their full subtree, so descendants are not duplicated as result roots.
    func matchingRoots(query: String, limit: Int) -> [FolderNode] {
        let needle = query.lowercased()
        var results: [FolderNode] = []
        var queue = children ?? []
        var index = 0
        while index < queue.count, results.count < limit {
            let node = queue[index]
            index += 1
            if node.url.lastPathComponent.lowercased().contains(needle) {
                results.append(node)
            } else if let children = node.children {
                queue.append(contentsOf: children)
            }
        }
        return results
    }

    static func relativePath(of url: URL, root: URL) -> String? {
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard url.path.hasPrefix(prefix) else { return nil }
        let relative = String(url.path.dropFirst(prefix.count))
        return relative.isEmpty ? nil : relative
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
