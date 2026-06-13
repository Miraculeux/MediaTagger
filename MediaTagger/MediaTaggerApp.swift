import SwiftUI
import AppKit
#if canImport(VLCKit)
import VLCKit
#endif

@main
struct MediaTaggerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()

    init() {
        #if DEBUG && canImport(VLCKit)
        // Stream libVLC's own diagnostics to stderr so issues like "DSF plays
        // but no sound" surface in the Run terminal instead of being silent.
        VLCLibrary.shared().debugLogging = true
        VLCLibrary.shared().debugLoggingLevel = 3
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 1000, minHeight: 600)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(
            width:  (NSScreen.main?.visibleFrame.width  ?? 1600),
            height: (NSScreen.main?.visibleFrame.height ?? 1000) * 0.85
        )
        .commands {
            CommandGroup(after: .newItem) {
                Button("Choose Root Folder…") { appState.pickRootFolder() }
                    .keyboardShortcut("o", modifiers: [.command])
            }
        }
    }
}

/// App lifecycle hooks: quit when the last window is closed (utility app behavior),
/// and release security-scoped resources on termination.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Best-effort: release any security-scoped URLs we opened during this session.
        SecurityScope.releaseAll()
    }
}
