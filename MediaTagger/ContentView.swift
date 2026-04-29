import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var appState: AppState

    /// Default startup split: sidebar 1/5, detail 3/10, file list takes the
    /// remainder (1/2). Captured once at view creation so user resizes are
    /// not overridden on every redraw.
    private let columnWidths: (sidebar: CGFloat, content: CGFloat, detail: CGFloat) = {
        let screenWidth = NSScreen.main?.visibleFrame.width ?? 1600
        let sidebar = screenWidth / 5           // 2/10
        let detail  = screenWidth * 3 / 10      // 3/10
        let content = screenWidth - sidebar - detail   // 5/10
        return (sidebar, content, detail)
    }()

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 180, ideal: columnWidths.sidebar)
        } content: {
            FileListView()
                .navigationSplitViewColumnWidth(min: 280, ideal: columnWidths.content)
        } detail: {
            DetailPane()
                .navigationSplitViewColumnWidth(min: 320, ideal: columnWidths.detail)
        }
        .navigationTitle(appState.rootURL?.lastPathComponent ?? "Media Tagger")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    appState.pickRootFolder()
                } label: {
                    Label("Choose Root", systemImage: "folder.badge.plus")
                }
            }
        }
    }
}
