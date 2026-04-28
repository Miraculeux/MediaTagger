import SwiftUI

@main
struct MusicTaggerApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 1000, minHeight: 600)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Choose Root Folder…") { appState.pickRootFolder() }
                    .keyboardShortcut("o", modifiers: [.command])
            }
        }
    }
}
