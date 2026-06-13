import Foundation
import AppKit
import Combine
import ImageIO
import UniformTypeIdentifiers

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
    /// Short description of the currently running batch (e.g. "Editing 12
    /// files…" / "Auto-repairing covers in 47 folders…"). Surfaced in the
    /// floating progress HUD so the user knows what they're cancelling.
    @Published var batchDescription: String = ""

    /// Currently running batch task, retained so `cancelBatch()` can stop it.
    /// Cleared automatically when the task completes.
    private var batchTask: Task<Void, Never>?

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

    /// Generation token for background title scans. Incremented whenever the
    /// folder changes so late results from an old scan are ignored.
    private var titleLoadGeneration: UInt64 = 0

    /// Pending "commit the new selection" task. Held so that fast keyboard
    /// navigation (holding ↓ in the file list) only triggers PlayerView /
    /// cover decode / metadata read for the file the user actually lands on,
    /// not every intermediate file the cursor passed over.
    private var commitSelectionTask: Task<Void, Never>?

    /// In-flight metadata read for the currently committed single selection.
    /// Cancelled whenever the folder/selection changes so stale reads don't
    /// continue consuming IO after the user navigates away.
    private var metadataLoadTask: Task<Void, Never>?

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
        titleLoadGeneration &+= 1
        let scanToken = titleLoadGeneration
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
        metadataLoadTask?.cancel()
        metadataLoadTask = nil
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
            // Lazily load titles in background. We fan out across a small
            // pool of workers — sidebar prefetch is dominated by per-file
            // open() + read() latency on external/network volumes, so
            // running a handful of reads in parallel cuts wall-clock time
            // by ~Nx. Cap the pool to avoid spinning up dozens of FDs on
            // huge folders.
            titleLoadTask = Task.detached { [weak self, files = files, scanToken] in
                let service = MetadataService()
                await withTaskGroup(of: (URL, String?, String?)?.self) { group in
                    var inFlight = 0
                    let maxConcurrent = 6
                    var iter = files.makeIterator()
                    func addNext() {
                        guard let f = iter.next() else { return }
                        inFlight += 1
                        group.addTask {
                            if Task.isCancelled { return nil }
                            guard let md = try? service.read(f.url) else { return (f.url, nil, nil) }
                            return (f.url, md.title, md.trackDisplay)
                        }
                    }
                    for _ in 0..<maxConcurrent { addNext() }
                    while let result = await group.next() {
                        inFlight -= 1
                        if Task.isCancelled { group.cancelAll(); return }
                        if let (url, title, track) = result {
                            await MainActor.run {
                                guard !Task.isCancelled,
                                      let self,
                                      self.titleLoadGeneration == scanToken
                                else { return }
                                if let title { self.titles[url] = title }
                                if let track { self.tracks[url] = track }
                            }
                        }
                        addNext()
                    }
                    _ = inFlight
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
            metadataLoadTask?.cancel()
            metadataLoadTask = nil
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
        metadataLoadTask?.cancel()
        metadataLoadTask = nil
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
        metadataLoadTask = Task.detached(priority: .userInitiated) { [weak self] in
            if Task.isCancelled { return }
            let result: Result<(MediaMetadata, MediaTechnicalInfo), Error>
            do { result = .success(try await service.readAll(url)) }
            catch { result = .failure(error) }
            if Task.isCancelled { return }
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
        batchDescription = "Editing \(targets.count) file\(targets.count == 1 ? "" : "s")…"
        lastError = nil
        let service = metadataService
        let total = targets.count
        // On a removable/external volume (USB HDD, SD card, …) running many
        // concurrent rewrites of large audio files thrashes the head and is
        // net-slower than 2-way parallelism. Internal/local volumes (SSD)
        // happily handle 6-way without degradation.
        let isExternal = isURLOnExternalVolume(targets.first?.url)
        let maxConcurrent = isExternal
            ? 2
            : max(2, min(ProcessInfo.processInfo.activeProcessorCount, 6))

        batchTask = Task.detached { [weak self] in
            struct ItemResult {
                let oldURL: URL
                let url: URL
                let title: String
                let track: String
                let error: String?
            }

            func sanitizedFilenameStem(from title: String) -> String {
                var s = title.trimmingCharacters(in: .whitespacesAndNewlines)
                // Finder disallows ":" and POSIX paths disallow "/".
                s = s.replacingOccurrences(of: "/", with: "-")
                s = s.replacingOccurrences(of: ":", with: "-")
                s = s.replacingOccurrences(of: "\\", with: "-")
                if let regex = try? NSRegularExpression(pattern: #"\s+"#) {
                    let range = NSRange(s.startIndex..., in: s)
                    s = regex.stringByReplacingMatches(in: s, range: range, withTemplate: " ")
                }
                // Drop ASCII control characters that can break file operations.
                s = String(s.unicodeScalars.filter {
                    let v = $0.value
                    return v >= 0x20 && v != 0x7F
                })
                return s.trimmingCharacters(in: .whitespacesAndNewlines)
            }

            func uniqueSiblingURL(for source: URL, stem: String) -> URL {
                let dir = source.deletingLastPathComponent()
                let ext = source.pathExtension
                let candidateName = ext.isEmpty ? stem : "\(stem).\(ext)"

                if source.lastPathComponent == candidateName { return source }

                var candidate = dir.appendingPathComponent(candidateName)
                var n = 2
                while FileManager.default.fileExists(atPath: candidate.path) {
                    let numbered = ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)"
                    candidate = dir.appendingPathComponent(numbered)
                    n += 1
                }
                return candidate
            }

            func normalizedCoverArt(_ data: Data) -> Data? {
                // Thread-safe ImageIO path (NSImage/lockFocus is not safe off the
                // main actor and pulled in an extra TIFF round-trip).
                guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
                let maxPixelSize: CGFloat = 1200
                let thumbOpts: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                ]
                guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOpts as CFDictionary)
                else { return nil }

                let out = NSMutableData()
                guard let dest = CGImageDestinationCreateWithData(
                    out, UTType.jpeg.identifier as CFString, 1, nil)
                else { return nil }
                let destOpts: [CFString: Any] = [
                    kCGImageDestinationLossyCompressionQuality: 0.82
                ]
                CGImageDestinationAddImage(dest, cg, destOpts as CFDictionary)
                guard CGImageDestinationFinalize(dest) else { return nil }
                return out as Data
            }

            var firstError: String?
            var completed = 0

            // Pre-normalize the batch cover ONCE so 12 files don't each
            // decode + re-encode a multi-MB scan in parallel — and so the
            // resulting ~200 KB JPEG fits inside the typical 256 KB FLAC
            // padding slot, letting `FlacFile.write` take the in-place
            // patch path instead of rewriting multi-GB audio bodies.
            var plan = plan
            if let raw = plan.coverArt, let n = normalizedCoverArt(raw) {
                plan.coverArt = n
                plan.coverMime = "image/jpeg"
            }

            await withTaskGroup(of: ItemResult.self) { group in
                var nextIndex = 0

                func enqueue(_ idx: Int) {
                    let file = targets[idx]
                    group.addTask {
                        do {
                            var currentURL = file.url
                            var md = (try? service.read(file.url)) ?? MediaMetadata()
                            plan.apply(to: &md,
                                       file: file,
                                       indexInSelection: idx,
                                       totalInSelection: total)

                            // Normalize at most once; reuse for both the
                            // embedded cover replacement and the sibling
                            // cover.jpg fallback to avoid a second decode.
                            var normalizedCache: Data? = nil
                            func normalized(_ data: Data) -> Data? {
                                if let cached = normalizedCache { return cached }
                                let result = normalizedCoverArt(data)
                                if let result { normalizedCache = result }
                                return result
                            }

                            if plan.repairCoverArt, let cover = md.coverArt,
                               let n = normalized(cover) {
                                md.coverArt = n
                                md.coverMimeType = "image/jpeg"
                            }

                            if plan.writeFolderCoverJPG,
                               let cover = md.coverArt {
                                let jpg: Data
                                if (md.coverMimeType ?? "").lowercased().contains("jpeg") {
                                    jpg = cover
                                } else if let n = normalized(cover) {
                                    jpg = n
                                } else {
                                    jpg = cover
                                }
                                let sidecar = currentURL.deletingLastPathComponent().appendingPathComponent("cover.jpg")
                                try jpg.write(to: sidecar, options: .atomic)
                            }

                            try service.write(md, to: currentURL)

                            if plan.filenameFromTitle,
                               let title = md.title {
                                let stem = sanitizedFilenameStem(from: title)
                                if !stem.isEmpty {
                                    let destination = uniqueSiblingURL(for: currentURL, stem: stem)
                                    if destination != currentURL {
                                        try FileManager.default.moveItem(at: currentURL, to: destination)
                                        currentURL = destination
                                    }
                                }
                            }

                            let newTitle = md.title ?? currentURL.lastPathComponent
                            let newTrack = md.trackDisplay ?? ""
                            return ItemResult(oldURL: file.url,
                                              url: currentURL,
                                              title: newTitle,
                                              track: newTrack,
                                              error: nil)
                        } catch {
                            return ItemResult(oldURL: file.url,
                                              url: file.url,
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
                    if Task.isCancelled { group.cancelAll(); continue }
                    completed += 1
                    let snapshot = result
                    let progress = Double(completed) / Double(total)
                    if let err = snapshot.error, firstError == nil {
                        firstError = "\(snapshot.oldURL.lastPathComponent): \(err)"
                    }
                    let didFail = snapshot.error != nil
                    await MainActor.run {
                        if !didFail {
                            if snapshot.oldURL != snapshot.url {
                                if let i = self?.files.firstIndex(where: { $0.id == snapshot.oldURL }) {
                                    self?.files[i] = MediaFile(id: snapshot.url)
                                }
                                if self?.selectedFileIDs.contains(snapshot.oldURL) == true {
                                    self?.selectedFileIDs.remove(snapshot.oldURL)
                                    self?.selectedFileIDs.insert(snapshot.url)
                                }
                                if self?.selectedFile?.id == snapshot.oldURL {
                                    self?.selectedFile = MediaFile(id: snapshot.url)
                                }
                                if let oldTitle = self?.titles.removeValue(forKey: snapshot.oldURL) {
                                    self?.titles[snapshot.url] = oldTitle
                                }
                                if let oldTrack = self?.tracks.removeValue(forKey: snapshot.oldURL) {
                                    self?.tracks[snapshot.url] = oldTrack
                                }
                                self?.techInfoCache.removeValue(forKey: snapshot.oldURL)
                            }
                            self?.titles[snapshot.url] = snapshot.title
                            self?.tracks[snapshot.url] = snapshot.track
                            // File contents changed — drop cached tech info.
                            self?.techInfoCache.removeValue(forKey: snapshot.url)
                        }
                        self?.batchProgress = progress
                    }

                    if nextIndex < total, !Task.isCancelled {
                        enqueue(nextIndex)
                        nextIndex += 1
                    }
                }
            }

            let wasCancelled = Task.isCancelled
            await MainActor.run {
                self?.batchInProgress = false
                self?.batchDescription = ""
                self?.batchTask = nil
                if wasCancelled {
                    self?.lastError = "Batch cancelled (\(completed)/\(total) files processed)"
                } else if let firstError {
                    self?.lastError = firstError
                }
            }
        }
    }

    /// True if `url` lives on a volume that's not the boot drive — used to
    /// dial down batch write concurrency on USB HDDs / network shares where
    /// many parallel rewrites only thrash the underlying media.
    private nonisolated func isURLOnExternalVolume(_ url: URL?) -> Bool {
        guard let url else { return false }
        let keys: Set<URLResourceKey> = [.volumeIsInternalKey, .volumeIsRemovableKey]
        guard let vals = try? url.resourceValues(forKeys: keys) else { return false }
        if vals.volumeIsRemovable == true { return true }
        if vals.volumeIsInternal == false { return true }
        return false
    }

    // MARK: - Auto-repair covers

    /// Recursively walk every subdirectory under `root` and embed a folder
    /// cover into music files that don't already have one. Rules per
    /// directory (mirrors the sidebar context-menu wording):
    ///
    ///   1. Sort the directory's audio files alphabetically. If the **first**
    ///      one already has an embedded cover, treat every sibling as
    ///      already-covered and skip the whole directory. This avoids
    ///      re-reading every file in long albums when a quick sample tells us
    ///      the album is already tagged.
    ///   2. Otherwise, look for a cover image in the same directory, in
    ///      priority order:
    ///         a) `cover.{jpg,jpeg,png,heic,heif}`
    ///         b) `front.{jpg,jpeg,png,heic,heif}`
    ///         c) image file whose stem matches the directory name
    ///         d) first image file (sorted alphabetically)
    ///   3. If a candidate is found, normalize it once (1200 px JPEG, ~200 KB)
    ///      so it fits inside FLAC's default padding slot and embed it into
    ///      every audio file in the directory.
    ///
    /// Skipped silently: directories without audio files, directories without
    /// a candidate cover image, and unreadable files.
    func autoRepairCovers(under root: URL) {
        guard !batchInProgress else { return }
        batchInProgress = true
        batchProgress = 0
        batchDescription = "Scanning \(root.lastPathComponent)…"
        lastError = nil

        let service = metadataService
        let isExternal = isURLOnExternalVolume(root)
        let maxConcurrent = isExternal ? 2 : 4
        let rootURL = root

        batchTask = Task.detached { [weak self] in
            // 1. Collect every subdirectory (including the root itself).
            let dirs = await Self.collectAudioDirs(under: rootURL)
            let totalDirs = dirs.count
            guard totalDirs > 0 else {
                await MainActor.run {
                    self?.batchInProgress = false
                    self?.batchDescription = ""
                    self?.batchTask = nil
                    self?.lastError = "No music files found under \(rootURL.lastPathComponent)"
                }
                return
            }
            if Task.isCancelled {
                await MainActor.run {
                    self?.batchInProgress = false
                    self?.batchDescription = ""
                    self?.batchTask = nil
                }
                return
            }
            await MainActor.run {
                self?.batchDescription = "Repairing covers in \(totalDirs) folder\(totalDirs == 1 ? "" : "s")…"
            }

            var completed = 0
            var stats = (repaired: 0, alreadyCovered: 0, noCandidate: 0, errors: 0)
            var firstError: String?

            await withTaskGroup(of: CoverRepairResult.self) { group in
                var iter = dirs.makeIterator()

                func enqueueNext() {
                    guard !Task.isCancelled, let dir = iter.next() else { return }
                    group.addTask {
                        await Self.repairCoversInDirectory(dir, service: service)
                    }
                }
                for _ in 0..<maxConcurrent { enqueueNext() }

                while let res = await group.next() {
                    if Task.isCancelled { group.cancelAll(); continue }
                    completed += 1
                    switch res.status {
                    case .repaired:        stats.repaired += 1
                    case .alreadyCovered:  stats.alreadyCovered += 1
                    case .noCandidate:     stats.noCandidate += 1
                    case .error(let s):
                        stats.errors += 1
                        if firstError == nil {
                            firstError = "\(res.dir.lastPathComponent): \(s)"
                        }
                    }
                    let progress = Double(completed) / Double(totalDirs)
                    await MainActor.run { self?.batchProgress = progress }
                    enqueueNext()
                }
            }

            let wasCancelled = Task.isCancelled
            await MainActor.run {
                guard let self else { return }
                self.batchInProgress = false
                self.batchProgress = 0
                self.batchDescription = ""
                self.batchTask = nil
                if let firstError {
                    self.lastError = firstError
                }
                // Refresh the currently-shown folder so embedded covers
                // appear in the editor without manual reload.
                self.refreshFiles()
                let summary = "Auto-repair covers" +
                              (wasCancelled ? " (cancelled)" : "") +
                              ": \(stats.repaired) repaired, " +
                              "\(stats.alreadyCovered) already covered, " +
                              "\(stats.noCandidate) without candidate" +
                              (stats.errors > 0 ? ", \(stats.errors) errors" : "")
                NSLog("MediaTagger: %@", summary)
                let alert = NSAlert()
                alert.messageText = wasCancelled
                    ? "Auto-repair covers cancelled"
                    : "Auto-repair covers complete"
                alert.informativeText = summary
                alert.alertStyle = .informational
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }
    }

    /// Cancel the currently-running batch (applyBatch / autoRepairCovers).
    /// Tasks already in flight finish their current file, then the loop
    /// exits early; UI returns to idle and a summary is shown.
    func cancelBatch() {
        batchTask?.cancel()
    }

    /// BFS the directory tree starting at `root`, returning every directory
    /// that contains at least one taggable audio/video file. Symlinks are
    /// not followed; hidden files / packages (e.g. `.app`) are skipped.
    private nonisolated static func collectAudioDirs(under root: URL) async -> [URL] {
        let fm = FileManager.default
        var out: [URL] = []
        var queue: [URL] = [root]
        while !queue.isEmpty {
            if Task.isCancelled { return out }
            let dir = queue.removeFirst()
            guard let items = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            var hasAudio = false
            for item in items {
                let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey])
                                  .isDirectory) ?? false
                if isDir {
                    queue.append(item)
                } else if MediaFile.isSupported(item) && !MediaFile.isImage(item) {
                    hasAudio = true
                }
            }
            if hasAudio { out.append(dir) }
        }
        return out
    }

    /// Returns the chosen cover image URL for `dir`, or `nil` if no candidate
    /// matches the priority list. Pure file-naming logic, no IO beyond the
    /// directory listing.
    private nonisolated static func pickCoverCandidate(images: [URL], dirName: String) -> URL? {
        // Common image extensions we'll embed. (Restricted vs. the read-only
        // set in MediaFile.imageExtensions — embedding TIFF/GIF in audio tags
        // works poorly in many players.)
        let coverExts: Set<String> = ["jpg", "jpeg", "png", "heic", "heif"]
        let candidates = images.filter { coverExts.contains($0.pathExtension.lowercased()) }
        if candidates.isEmpty { return nil }

        func firstMatching(_ stem: String) -> URL? {
            candidates.first {
                $0.deletingPathExtension().lastPathComponent
                    .caseInsensitiveCompare(stem) == .orderedSame
            }
        }
        if let u = firstMatching("cover") { return u }
        if let u = firstMatching("front") { return u }
        if let u = firstMatching(dirName) { return u }
        return candidates.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }.first
    }

    private nonisolated static func repairCoversInDirectory(
        _ dir: URL,
        service: MetadataService
    ) async -> CoverRepairResult {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else {
            return CoverRepairResult(dir: dir, repairedFiles: 0, status: .noCandidate)
        }
        let audioFiles = items
            .filter { MediaFile.isSupported($0) && !MediaFile.isImage($0) }
            .sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }
        guard let first = audioFiles.first else {
            return CoverRepairResult(dir: dir, repairedFiles: 0, status: .noCandidate)
        }

        // Sample the first file: if it already has a cover, treat the whole
        // directory as done. This matches the spec and keeps the scan O(dirs)
        // instead of O(files) on already-tagged libraries.
        if let firstMd = try? service.read(first), firstMd.coverArt != nil {
            return CoverRepairResult(dir: dir, repairedFiles: 0, status: .alreadyCovered)
        }

        let imageItems = items.filter { MediaFile.isImage($0) }
        guard let coverURL = pickCoverCandidate(
            images: imageItems,
            dirName: dir.lastPathComponent
        ) else {
            return CoverRepairResult(dir: dir, repairedFiles: 0, status: .noCandidate)
        }
        guard let raw = try? Data(contentsOf: coverURL) else {
            return CoverRepairResult(
                dir: dir, repairedFiles: 0,
                status: .error("Could not read \(coverURL.lastPathComponent)"))
        }
        // Normalize once to ~200 KB JPEG so the embed fits typical FLAC
        // padding slots and the in-place patch path stays valid.
        let normalized: Data
        let mime: String
        if let n = normalizedCoverJPEG(raw) {
            normalized = n
            mime = "image/jpeg"
        } else {
            normalized = raw
            mime = mimeForImageURL(coverURL)
        }

        var repairedCount = 0
        var lastErr: String?
        for file in audioFiles {
            if Task.isCancelled { break }
            do {
                var md = (try? service.read(file)) ?? MediaMetadata()
                md.coverArt = normalized
                md.coverMimeType = mime
                try service.write(md, to: file)
                repairedCount += 1
            } catch {
                lastErr = error.localizedDescription
            }
        }

        if repairedCount == 0, let lastErr {
            return CoverRepairResult(dir: dir, repairedFiles: 0, status: .error(lastErr))
        }
        return CoverRepairResult(dir: dir, repairedFiles: repairedCount, status: .repaired)
    }

    /// Status type for `repairCoversInDirectory`. Kept at file scope so the
    /// `TaskGroup` element type stays a simple struct value.
    private enum CoverRepairStatus {
        case repaired, alreadyCovered, noCandidate, error(String)
    }

    private struct CoverRepairResult {
        let dir: URL
        let repairedFiles: Int
        let status: CoverRepairStatus
    }

    private nonisolated static func normalizedCoverJPEG(_ data: Data) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let thumbOpts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 1200,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOpts as CFDictionary)
        else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            out, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(dest, cg,
            [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    private nonisolated static func mimeForImageURL(_ url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "png":          return "image/png"
        case "heic", "heif": return "image/heic"
        default:             return "image/jpeg"
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
