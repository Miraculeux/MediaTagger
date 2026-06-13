import SwiftUI

/// Floating capsule pinned to the bottom of the main window while a long
/// batch is in flight (apply batch / auto-repair covers). Shows a progress
/// bar, a short description of what's running, and a Cancel button.
///
/// The bar appears for **all** long batches, not just operations that
/// originated from the visible editor view. Auto-repair covers is fired
/// from the sidebar context menu, so without this HUD there's no obvious
/// way to interrupt it.
struct BatchProgressOverlay: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        if appState.batchInProgress {
            HStack(spacing: 10) {
                ProgressView(value: appState.batchProgress)
                    .progressViewStyle(.linear)
                    .frame(width: 220)
                Text(appState.batchDescription.isEmpty
                     ? "Working…"
                     : appState.batchDescription)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Cancel") {
                    appState.cancelBatch()
                }
                .keyboardShortcut(".", modifiers: .command)
                .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.thinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
            .padding(12)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
