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
            Task.detached { [weak self, files = files] in
                for f in files {
                    if let md = try? MetadataService().read(f.url) {
                        let title = md.title
                        let track = md.trackDisplay
                        await MainActor.run {
                            if let title { self?.titles[f.url] = title }
                            if let track { self?.tracks[f.url] = track }
                        }
                    }
                }
            }
        } catch {
            lastError = error.localizedDescription
            files = []
        }
    }

    // MARK: - Selection / metadata

    var selectedFiles: [MediaFile] {
        files.filter { selectedFileIDs.contains($0.id) }
    }

    /// Update selection from the file list (UI calls this).
    func setSelection(_ ids: Set<URL>) {
        selectedFileIDs = ids
        isDirty = false
        if ids.count == 1, let file = files.first(where: { ids.contains($0.id) }) {
            selectedFile = file
            do {
                metadata = try metadataService.read(file.url)
            } catch {
                lastError = error.localizedDescription
                metadata = MediaMetadata()
            }
        } else {
            selectedFile = nil
            metadata = nil
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
    func applyBatch(_ plan: BatchPlan) {
        let targets = files.filter { selectedFileIDs.contains($0.id) }
        guard !targets.isEmpty else { return }
        batchInProgress = true
        batchProgress = 0
        lastError = nil
        let service = metadataService
        Task.detached { [weak self] in
            var firstError: String?
            for (idx, file) in targets.enumerated() {
                do {
                    var md = (try? service.read(file.url)) ?? MediaMetadata()
                    plan.apply(to: &md, file: file, indexInSelection: idx, totalInSelection: targets.count)
                    let newTitle = md.title ?? file.name
                    try service.write(md, to: file.url)
                    let newTrack = md.trackDisplay ?? ""
                    await MainActor.run {
                        self?.titles[file.url] = newTitle
                        self?.tracks[file.url] = newTrack
                        self?.batchProgress = Double(idx + 1) / Double(targets.count)
                    }
                } catch {
                    if firstError == nil { firstError = "\(file.name): \(error.localizedDescription)" }
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
