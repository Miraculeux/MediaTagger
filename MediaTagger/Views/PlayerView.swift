import SwiftUI
import AVKit
import AVFoundation
import AppKit

/// Lightweight AVKit-backed player for the currently selected media file.
///
/// Wraps `AVPlayerView` directly via `NSViewRepresentable` instead of using
/// SwiftUI's `VideoPlayer` — `VideoPlayer` was crashing during SwiftUI's
/// generic-metadata initialization (`PlatformViewRepresentableFeature`)
/// when embedded inside `ScrollView` / `NavigationSplitView`. The AppKit
/// view gives the same compact transport bar for audio without that issue.
///
/// Some container/codec combinations (Ogg, Opus, Matroska, WebM, DSD, AVI)
/// are not natively supported by AVFoundation on macOS — for those we show
/// a small "Playback not supported" placeholder.
struct PlayerView: View {
    let url: URL

    @StateObject private var controller = PlayerController()

    var body: some View {
        Group {
            if PlayerView.isPlayable(url) {
                AVPlayerViewRepresentable(player: controller.player,
                                          showsFullScreen: isVideo(url))
                    .frame(height: isVideo(url) ? 240 : 50)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "speaker.slash")
                        .foregroundStyle(.secondary)
                    Text("Playback not supported for .\(url.pathExtension.lowercased()) files")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 8)
                .frame(height: 36)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .onAppear { if PlayerView.isPlayable(url) { controller.load(url) } }
        .onChange(of: url) { _, new in
            if PlayerView.isPlayable(new) { controller.load(new) } else { controller.stop() }
        }
        .onDisappear { controller.stop() }
    }

    private func isVideo(_ url: URL) -> Bool {
        ["mp4", "m4v", "mov"].contains(url.pathExtension.lowercased())
    }

    /// Extensions AVFoundation can decode out of the box on macOS.
    static func isPlayable(_ url: URL) -> Bool {
        playableExtensions.contains(url.pathExtension.lowercased())
    }

    private static let playableExtensions: Set<String> = [
        // Audio
        "mp3", "m4a", "m4b", "aac", "alac", "wav", "aiff", "aif", "aifc", "flac",
        // Video
        "mp4", "m4v", "mov",
    ]
}

/// Owns the `AVPlayer` instance so it survives view re-creation.
final class PlayerController: ObservableObject {
    let player = AVPlayer()
    private var currentURL: URL?

    func load(_ url: URL) {
        guard url != currentURL else { return }
        currentURL = url
        player.pause()
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        player.seek(to: .zero)
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        currentURL = nil
    }
}

/// Direct AppKit AVPlayerView wrapper — avoids SwiftUI `VideoPlayer` entirely.
private struct AVPlayerViewRepresentable: NSViewRepresentable {
    let player: AVPlayer
    let showsFullScreen: Bool

    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.player = player
        v.controlsStyle = .inline
        v.showsFullScreenToggleButton = showsFullScreen
        v.videoGravity = .resizeAspect
        return v
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player { nsView.player = player }
        nsView.showsFullScreenToggleButton = showsFullScreen
    }
}
