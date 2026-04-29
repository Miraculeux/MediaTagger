import Foundation

/// Tracks security-scoped URLs opened with `startAccessingSecurityScopedResource`
/// so they can be released cleanly on app termination (and so we don't accidentally
/// leak nested calls when the user re-picks the same folder).
enum SecurityScope {
    private static let lock = NSLock()
    private static var openURLs: Set<URL> = []

    static func start(_ url: URL) {
        lock.lock(); defer { lock.unlock() }
        if openURLs.contains(url) { return }
        if url.startAccessingSecurityScopedResource() {
            openURLs.insert(url)
        }
    }

    static func stop(_ url: URL) {
        lock.lock(); defer { lock.unlock() }
        if openURLs.remove(url) != nil {
            url.stopAccessingSecurityScopedResource()
        }
    }

    static func releaseAll() {
        lock.lock(); defer { lock.unlock() }
        for url in openURLs { url.stopAccessingSecurityScopedResource() }
        openURLs.removeAll()
    }
}
