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
                VStack(spacing: 4) {
                    AVPlayerViewRepresentable(player: controller.player,
                                              showsFullScreen: isVideo(url))
                        .frame(height: isVideo(url) ? 240 : 50)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    // AVPlayerView's inline controls don't expose a volume
                    // slider, so layer one on top in a small bar that mirrors
                    // the VLC fallback player's transport.
                    VolumeBar(volume: $controller.volume)
                }
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

    /// 0…100, persisted across files.
    @Published var volume: Double {
        didSet {
            player.volume = Float(volume / 100.0)
            UserDefaults.standard.set(volume, forKey: Self.volumeKey)
        }
    }

    private static let volumeKey = "PlayerView.volume"

    init() {
        let stored = UserDefaults.standard.object(forKey: Self.volumeKey) as? Double
        self.volume = stored ?? 80
        player.volume = Float((stored ?? 80) / 100.0)
    }

    func load(_ url: URL) {
        guard url != currentURL else { return }
        currentURL = url
        player.pause()
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        player.seek(to: .zero)
        player.volume = Float(volume / 100.0)
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        currentURL = nil
    }
}

/// Compact mute-button + volume-slider bar shared by the AVFoundation player.
/// (The VLC player builds its own equivalent inline because it lives inside an
/// `NSView`-based transport.)
private struct VolumeBar: View {
    @Binding var volume: Double
    @State private var preMute: Double = 80

    var body: some View {
        HStack(spacing: 6) {
            Spacer()
            Button {
                if volume > 0 { preMute = volume; volume = 0 }
                else { volume = preMute > 0 ? preMute : 80 }
            } label: {
                Image(systemName: speakerSymbol)
                    .frame(width: 18)
            }
            .buttonStyle(.borderless)
            Slider(value: $volume, in: 0...100)
                .frame(width: 100)
                .controlSize(.mini)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
    }

    private var speakerSymbol: String {
        switch Int(volume) {
        case 0: return "speaker.slash.fill"
        case 1...33: return "speaker.wave.1.fill"
        case 34...66: return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
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
