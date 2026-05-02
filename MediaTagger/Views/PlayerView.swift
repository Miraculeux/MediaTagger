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
/// AVFoundation can only demux a subset of containers on macOS. For
/// everything else (MKV, WebM, OGG, Opus, AVI with non-Apple codecs, DSD,
/// …) we fall back to `VLCPlayerView` (libVLC), which ships in the bundle
/// when `Frameworks/VLCKit.framework` is present (see
/// `Scripts/fetch_vlckit.sh`).
struct PlayerView: View {
    let url: URL

    @StateObject private var controller = PlayerController()

    var body: some View {
        Group {
            if PlayerView.isAVPlayable(url) {
                AVPlayerViewRepresentable(player: controller.player,
                                          showsFullScreen: isVideo(url))
                    .frame(height: isVideo(url) ? 240 : 50)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                // Hand off to VLC for unsupported containers. When VLCKit
                // isn't linked, VLCPlayerView shows the same chip the
                // editor used to display before.
                VLCPlayerView(url: url, isVideo: isVideo(url))
            }
        }
        .onAppear { if PlayerView.isAVPlayable(url) { controller.load(url) } }
        .onChange(of: url) { _, new in
            if PlayerView.isAVPlayable(new) { controller.load(new) } else { controller.stop() }
        }
        .onDisappear { controller.stop() }
    }

    private func isVideo(_ url: URL) -> Bool {
        let v: Set<String> = ["mp4", "m4v", "mov", "mkv", "webm", "avi"]
        return v.contains(url.pathExtension.lowercased())
    }

    /// Extensions AVFoundation can decode out of the box on macOS.
    static func isAVPlayable(_ url: URL) -> Bool {
        avPlayableExtensions.contains(url.pathExtension.lowercased())
    }

    private static let avPlayableExtensions: Set<String> = [
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
