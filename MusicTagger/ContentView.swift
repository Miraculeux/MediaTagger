import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .frame(minWidth: 220)
        } content: {
            FileListView()
                .frame(minWidth: 320)
        } detail: {
            DetailPane()
                .frame(minWidth: 360)
        }
        .navigationTitle(appState.rootURL?.lastPathComponent ?? "Music Tagger")
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
