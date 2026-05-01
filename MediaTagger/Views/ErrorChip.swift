import SwiftUI

/// Compact error chip used in the bottom bar of the metadata / batch editors.
///
/// Shows a small red "exclamation" icon plus a single-line truncated message
/// so it never steals the buttons' real estate. The full text is available
/// via tooltip on hover, by tapping the chip (which opens an alert) or by
/// dismissing it with the ✕ button.
struct ErrorChip: View {
    let message: String
    let onDismiss: () -> Void

    @State private var showFull = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(0)          // let buttons keep their width
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Dismiss error")
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Color.red.opacity(0.08), in: Capsule())
        .help(message)
        .contentShape(Capsule())
        .onTapGesture { showFull = true }
        .alert("Error", isPresented: $showFull) {
            Button("Copy") {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(message, forType: .string)
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text(message)
        }
    }
}
