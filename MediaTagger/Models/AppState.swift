import Foundation
import AppKit
import Combine

@MainActor
final class AppState: ObservableObject {
    // Navigation
    @Published var rootURL: URL?
    @Published var selectedFolder: URL?
    @Published var files: [MediaFile] = []
    @Published var selectedFile: MediaFile?
    /// Multi-selection set (file URLs). When count == 1 it stays in sync with `selectedFile`.
    @Published var selectedFileIDs: Set<URL> = []

    // Metadata for the currently-selected file
    @Published var metadata: MediaMetadata?
    /// Technical (audio/container) properties for the currently-selected file.
    @Published var technicalInfo: MediaTechnicalInfo?
    @Published var titles: [URL: String] = [:]   // cached titles for the file list
    @Published var tracks: [URL: String] = [:]   // cached track-number display ("03 / 12")

    // Batch progress
    @Published var batchInProgress: Bool = false
    @Published var batchProgress: Double = 0   // 0...1

    // Status / errors
    @Published var lastError: String?
    @Published var isDirty: Bool = false

    private var rootBookmark: Data?
    private let bookmarkKey = "rootBookmark"
    private let metadataService = MetadataService()
    /// Cache of stream-level tech info, keyed by URL. Invalidated when the
    /// root folder changes or after a save (which may alter file size).
    private var techInfoCache: [URL: MediaTechnicalInfo] = [:]

    /// Monotonic token to discard stale background reads when the user clicks
    /// rapidly between files.
    private var loadGeneration: UInt64 = 0

    /// Background task that warms up `titles` / `tracks` for the current
    /// folder. Cancelled when the folder changes so we don't keep parsing
    /// the previous folder's files after the user navigates away.
    private var titleLoadTask: Task<Void, Never>?

    /// Pending "commit the new selection" task. Held so that fast keyboard
    /// navigation (holding ↓ in the file list) only triggers PlayerView /
    /// cover decode / metadata read for the file the user actually lands on,
    /// not every intermediate file the cursor passed over.
    private var commitSelectionTask: Task<Void, Never>?

    /// How long to wait after a selection change before committing it. Below
    /// the perceptual threshold for a single click but long enough to coalesce
    /// arrow-key autorepeat (system default repeat rate is ~30 ms).
    private static let selectionCommitDelay: Duration = .milliseconds(90)

    init() {
        restoreRootBookmark()
    }

    // MARK: - Root folder

    func pickRootFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            setRoot(url)
            persistBookmark(for: url)
        }
    }

    func setRoot(_ url: URL) {
        // Release any previous root, then claim the new one.
        if let old = rootURL, old != url { SecurityScope.stop(old) }
        SecurityScope.start(url)
        rootURL = url
        selectedFolder = url
        loadFiles(in: url)
    }

    // MARK: - File list

    func loadFiles(in folder: URL) {
        selectedFolder = folder
        selectedFile = nil
        selectedFileIDs = []
        metadata = nil
        technicalInfo = nil
        techInfoCache.removeAll()
        // Cancel any in-flight title scan from the previous folder so we
        // don't waste IO/CPU parsing files the user no longer cares about
        // and don't poison `titles` with stale entries.
        titleLoadTask?.cancel()
        titleLoadTask = nil
        // Also drop any debounced selection commit from the previous folder
        // so it can't fire after the new file list has replaced `files`.
        commitSelectionTask?.cancel()
        commitSelectionTask = nil
        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
            let mediaURLs = contents
                .filter { MediaFile.isSupported($0) }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            files = mediaURLs.map { MediaFile(id: $0) }
            // lazily load titles in background
            titleLoadTask = Task.detached { [weak self, files = files] in
                let service = MetadataService()
                for f in files {
                    if Task.isCancelled { return }
                    guard let md = try? service.read(f.url) else { continue }
                    let title = md.title
                    let track = md.trackDisplay
                    await MainActor.run {
                        guard !Task.isCancelled else { return }
                        if let title { self?.titles[f.url] = title }
                        if let track { self?.tracks[f.url] = track }
                    }
                }
            }
        } catch {
            lastError = error.localizedDescription
            files = []
        }
    }

    /// Re-scan the current folder, preserving the user's selection where
    /// possible. Used by the file-list refresh button / context menu.
    func refreshFiles() {
        guard let folder = selectedFolder ?? rootURL else { return }
        let previousSelection = selectedFileIDs
        loadFiles(in: folder)
        let still = previousSelection.intersection(Set(files.map(\.id)))
        if !still.isEmpty { setSelection(still) }
    }

    // MARK: - Selection / metadata

    var selectedFiles: [MediaFile] {
        files.filter { selectedFileIDs.contains($0.id) }
    }

    /// Update selection from the file list (UI calls this).
    ///
    /// `selectedFileIDs` is updated synchronously so the Table's selection
    /// highlight tracks the cursor without lag. The heavier work (assigning
    /// `selectedFile`, which causes PlayerView to reload AVPlayer and the
    /// cover-art `.task` to re-run, plus kicking off the off-main metadata
    /// read) is debounced by `selectionCommitDelay`. Holding ↓ over a list
    /// of files therefore stops flickering the right pane on every step —
    /// only the file the user lands on is fully loaded.
    func setSelection(_ ids: Set<URL>) {
        selectedFileIDs = ids
        isDirty = false
        commitSelectionTask?.cancel()

        if ids.count == 1, let file = files.first(where: { ids.contains($0.id) }) {
            // If the same file is already selected, nothing to do.
            if selectedFile?.id == file.id { return }
            commitSelectionTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: Self.selectionCommitDelay)
                if Task.isCancelled { return }
                self?.commitSingleSelection(file)
            }
        } else {
            // Multi-select / clear: commit immediately. There's no expensive
            // per-file UI to thrash here — the batch editor doesn't reload
            // anything when individual rows toggle in/out of the selection.
            loadGeneration &+= 1
            selectedFile = nil
            metadata = nil
            technicalInfo = nil
        }
    }

    /// Apply a debounced single-file selection: swap `selectedFile`, show any
    /// cached technical info instantly, and kick off the off-main metadata
    /// read whose result is gated by `loadGeneration` so a later selection
    /// change wins if this read takes a while.
    private func commitSingleSelection(_ file: MediaFile) {
        selectedFile = file
        // Don't clear `metadata` here — keeping the previous tags on
        // screen while the new file loads avoids a "spinner flash" on
        // every selection change. The new metadata replaces the old one
        // in a single update when the off-main read finishes (typically
        // <50 ms now that all readers stream via FileHandle).
        loadGeneration &+= 1
        let token = loadGeneration
        let service = metadataService
        let url = file.url
        // Show cached tech info immediately if we've seen this file in
        // this session; otherwise clear stale tech from the previous file.
        technicalInfo = techInfoCache[url]
        Task.detached(priority: .userInitiated) { [weak self] in
            let result: Result<(MediaMetadata, MediaTechnicalInfo), Error>
            do { result = .success(try await service.readAll(url)) }
            catch { result = .failure(error) }
            await MainActor.run {
                guard let self, self.loadGeneration == token else { return }
                switch result {
                case .success(let (md, tech)):
                    self.metadata = md
                    self.technicalInfo = tech
                    self.techInfoCache[url] = tech
                case .failure(let err):
                    self.lastError = err.localizedDescription
                    self.metadata = MediaMetadata()
                }
            }
        }
    }

    func selectFile(_ file: MediaFile?) {
        if let file { setSelection([file.id]) } else { setSelection([]) }
    }

    func saveCurrent() {
        guard let file = selectedFile, let md = metadata else { return }
        do {
            try metadataService.write(md, to: file.url)
            isDirty = false
            titles[file.url] = md.title ?? file.name
            tracks[file.url] = md.trackDisplay ?? ""
            // File bytes changed — invalidate cached tech info so we re-read
            // the new file size on the next selection of this URL.
            techInfoCache.removeValue(forKey: file.url)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func updateTag(id: UUID, key: String? = nil, value: String? = nil) {
        guard var md = metadata, let idx = md.tags.firstIndex(where: { $0.id == id }) else { return }
        if let key { md.tags[idx].key = key }
        if let value { md.tags[idx].value = value }
        metadata = md
        isDirty = true
    }

    func addTag(key: String = "NEWKEY", value: String = "") {
        guard var md = metadata else { return }
        md.tags.append(.init(key: key, value: value))
        metadata = md
        isDirty = true
    }

    func removeTag(id: UUID) {
        guard var md = metadata else { return }
        md.tags.removeAll { $0.id == id }
        metadata = md
        isDirty = true
    }

    /// Set or clear the single tag with the given key. Empty `value` removes the tag.
    func setStandardTag(_ key: String, _ value: String) {
        guard var md = metadata else {
            metadata = MediaMetadata()
            setStandardTag(key, value)
            return
        }
        md.setTag(key, value.isEmpty ? nil : value)
        metadata = md
        isDirty = true
    }

    func standardTagValue(_ key: String) -> String {
        metadata?.first(key) ?? ""
    }

    // MARK: - Batch operations

    /// Apply `plan` to every file in `selectedFiles`, in the order they appear in `files`.
    /// Reads each file's existing metadata, mutates it, then writes it back.
    ///
    /// Uses a bounded `TaskGroup` so multiple files are processed concurrently
    /// (cap matches the available cores, ceiling 6 to avoid thrashing the
    /// disk on spinning media or external volumes). The per-file `idx` passed
    /// to `BatchPlan.apply` still reflects the original selection order, so
    /// `renumberTracks` produces the same TRACKNUMBER values regardless of
    /// completion order.
    func applyBatch(_ plan: BatchPlan) {
        let targets = files.filter { selectedFileIDs.contains($0.id) }
        guard !targets.isEmpty else { return }
        batchInProgress = true
        batchProgress = 0
        lastError = nil
        let service = metadataService
        let total = targets.count
        let maxConcurrent = max(2, min(ProcessInfo.processInfo.activeProcessorCount, 6))

        Task.detached { [weak self] in
            struct ItemResult {
                let url: URL
                let title: String
                let track: String
                let error: String?
            }

            var firstError: String?
            var completed = 0

            await withTaskGroup(of: ItemResult.self) { group in
                var nextIndex = 0

                func enqueue(_ idx: Int) {
                    let file = targets[idx]
                    group.addTask {
                        do {
                            var md = (try? service.read(file.url)) ?? MediaMetadata()
                            plan.apply(to: &md,
                                       file: file,
                                       indexInSelection: idx,
                                       totalInSelection: total)
                            let newTitle = md.title ?? file.name
                            try service.write(md, to: file.url)
                            let newTrack = md.trackDisplay ?? ""
                            return ItemResult(url: file.url,
                                              title: newTitle,
                                              track: newTrack,
                                              error: nil)
                        } catch {
                            return ItemResult(url: file.url,
                                              title: file.name,
                                              track: "",
                                              error: error.localizedDescription)
                        }
                    }
                }

                // Seed the group up to the concurrency cap.
                while nextIndex < min(maxConcurrent, total) {
                    enqueue(nextIndex)
                    nextIndex += 1
                }

                // As each task completes, publish its result and enqueue the next.
                while let result = await group.next() {
                    completed += 1
                    let snapshot = result
                    let progress = Double(completed) / Double(total)
                    if let err = snapshot.error, firstError == nil {
                        firstError = "\(snapshot.url.lastPathComponent): \(err)"
                    }
                    let didFail = snapshot.error != nil
                    await MainActor.run {
                        if !didFail {
                            self?.titles[snapshot.url] = snapshot.title
                            self?.tracks[snapshot.url] = snapshot.track
                            // File contents changed — drop cached tech info.
                            self?.techInfoCache.removeValue(forKey: snapshot.url)
                        }
                        self?.batchProgress = progress
                    }

                    if nextIndex < total {
                        enqueue(nextIndex)
                        nextIndex += 1
                    }
                }
            }

            await MainActor.run {
                self?.batchInProgress = false
                if let firstError { self?.lastError = firstError }
            }
        }
    }

    // MARK: - Bookmark persistence

    private func persistBookmark(for url: URL) {
        do {
            let data = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(data, forKey: bookmarkKey)
            rootBookmark = data
        } catch {
            lastError = "Failed to bookmark: \(error.localizedDescription)"
        }
    }

    private func restoreRootBookmark() {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return }
        var stale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            setRoot(url)
        } catch {
            // ignore – user will pick again
        }
    }
}
