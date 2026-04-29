import SwiftUI

/// Switches between single-file editor and batch editor based on the
/// current selection size.
struct DetailPane: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        if appState.selectedFileIDs.count > 1 {
            BatchEditorView()
        } else {
            MetadataEditorView()
        }
    }
}
