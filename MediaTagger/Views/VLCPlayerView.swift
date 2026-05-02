import SwiftUI
import AppKit
#if canImport(VLCKit)
import VLCKit
#endif

/// Fallback player backed by libVLC for containers AVFoundation can't demux on
/// macOS (MKV, WebM, AVI with non-Apple codecs, Opus, OGG, DSD, …). Compiled
/// in only when VLCKit is available — when the framework isn't linked the
/// view falls back to a small "Playback not supported" chip.
struct VLCPlayerView: View {
    let url: URL
    let isVideo: Bool

    var body: some View {
        #if canImport(VLCKit)
        VLCRepresentable(url: url)
            .frame(height: isVideo ? 240 : 50)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        #else
        UnsupportedChip(ext: url.pathExtension.lowercased())
        #endif
    }
}

/// Small inline placeholder shown when neither AVFoundation nor VLCKit can
/// (or want to) play the file.
struct UnsupportedChip: View {
    let ext: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "speaker.slash")
                .foregroundStyle(.secondary)
            Text("Playback not supported for .\(ext) files")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 8)
        .frame(height: 36)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    }
}

#if canImport(VLCKit)

/// Bridges a `VLCMediaPlayer` into SwiftUI. Uses an `NSView` as the drawable
/// surface for video, plus a thin AppKit transport bar (play/pause + slider)
/// since `AVPlayerView`'s built-in controls are AVFoundation-specific.
private struct VLCRepresentable: NSViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.makeContainer()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.update(url: url)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator: NSObject, VLCMediaPlayerDelegate {
        private let player = VLCMediaPlayer()
        private var currentURL: URL
        private weak var videoSurface: NSView?
        private weak var slider: NSSlider?
        private weak var playButton: NSButton?
        private weak var timeLabel: NSTextField?
        private weak var volumeSlider: NSSlider?
        private weak var volumeButton: NSButton?
        private var isUserSeeking = false
        /// Persisted across files so the user's chosen level survives selection changes.
        private static let volumeDefaultsKey = "VLCPlayerView.volume"
        private var volume: Int = {
            let v = UserDefaults.standard.object(forKey: Coordinator.volumeDefaultsKey) as? Int
            return v ?? 80
        }()

        init(url: URL) {
            self.currentURL = url
            super.init()
            player.delegate = self
        }

        func makeContainer() -> NSView {
            let container = NSView()
            container.wantsLayer = true

            // Video surface — VLC draws into this view.
            let surface = NSView()
            surface.wantsLayer = true
            surface.layer?.backgroundColor = NSColor.black.cgColor
            surface.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(surface)
            videoSurface = surface
            player.drawable = surface

            // Transport bar.
            let play = NSButton()
            play.bezelStyle = .accessoryBarAction
            play.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Play")
            play.target = self
            play.action = #selector(togglePlay)
            play.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(play)
            playButton = play

            let s = NSSlider(value: 0, minValue: 0, maxValue: 1, target: self, action: #selector(seekChanged(_:)))
            s.controlSize = .small
            s.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(s)
            slider = s

            let label = NSTextField(labelWithString: "00:00")
            label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            label.textColor = .secondaryLabelColor
            label.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(label)
            timeLabel = label

            // Mute toggle + volume slider (right side of the transport bar).
            let volBtn = NSButton()
            volBtn.bezelStyle = .accessoryBarAction
            volBtn.image = NSImage(systemSymbolName: volumeSymbol(for: volume),
                                   accessibilityDescription: "Mute")
            volBtn.target = self
            volBtn.action = #selector(toggleMute)
            volBtn.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(volBtn)
            volumeButton = volBtn

            let vol = NSSlider(value: Double(volume), minValue: 0, maxValue: 200,
                               target: self, action: #selector(volumeChanged(_:)))
            vol.controlSize = .small
            vol.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(vol)
            volumeSlider = vol

            NSLayoutConstraint.activate([
                surface.topAnchor.constraint(equalTo: container.topAnchor),
                surface.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                surface.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                surface.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -28),

                play.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
                play.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4),
                play.widthAnchor.constraint(equalToConstant: 24),

                s.leadingAnchor.constraint(equalTo: play.trailingAnchor, constant: 8),
                s.centerYAnchor.constraint(equalTo: play.centerYAnchor),
                s.trailingAnchor.constraint(equalTo: label.leadingAnchor, constant: -8),

                label.trailingAnchor.constraint(equalTo: volBtn.leadingAnchor, constant: -8),
                label.centerYAnchor.constraint(equalTo: play.centerYAnchor),

                volBtn.centerYAnchor.constraint(equalTo: play.centerYAnchor),
                volBtn.widthAnchor.constraint(equalToConstant: 22),

                vol.leadingAnchor.constraint(equalTo: volBtn.trailingAnchor, constant: 4),
                vol.centerYAnchor.constraint(equalTo: play.centerYAnchor),
                vol.widthAnchor.constraint(equalToConstant: 80),
                vol.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            ])

            applyVolume()
            load(currentURL)
            return container
        }

        func update(url: URL) {
            guard url != currentURL else { return }
            currentURL = url
            load(url)
        }

        func stop() {
            player.stop()
        }

        private func load(_ url: URL) {
            player.stop()
            player.media = VLCMedia(url: url)
            slider?.doubleValue = 0
            timeLabel?.stringValue = "00:00"
            // Match AVPlayer behaviour: load the file but wait for the user
            // to press play. Otherwise selecting an MKV/AVI in the file list
            // would start blasting audio immediately.
            updatePlayButton()
        }

        @objc private func togglePlay() {
            if player.isPlaying { player.pause() } else { player.play() }
            updatePlayButton()
        }

        @objc private func seekChanged(_ sender: NSSlider) {
            // Track drag state via the current event so we don't fight live updates.
            if let event = NSApp.currentEvent {
                switch event.type {
                case .leftMouseDown: isUserSeeking = true
                case .leftMouseUp:
                    isUserSeeking = false
                    player.position = Float(sender.doubleValue)
                default:
                    player.position = Float(sender.doubleValue)
                }
            } else {
                player.position = Float(sender.doubleValue)
            }
        }

        private func updatePlayButton() {
            let name = player.isPlaying ? "pause.fill" : "play.fill"
            playButton?.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        }

        // MARK: Volume

        @objc private func volumeChanged(_ sender: NSSlider) {
            volume = Int(sender.doubleValue.rounded())
            applyVolume()
            UserDefaults.standard.set(volume, forKey: Self.volumeDefaultsKey)
        }

        @objc private func toggleMute() {
            if player.audio?.volume ?? 0 > 0 {
                player.audio?.volume = 0
                volumeButton?.image = NSImage(systemSymbolName: "speaker.slash.fill",
                                              accessibilityDescription: "Unmute")
            } else {
                applyVolume()
            }
        }

        /// Push the current `volume` into libVLC. libVLC's audio output may not
        /// be ready immediately after `play()`, so we re-apply on each load and
        /// state change as well.
        private func applyVolume() {
            player.audio?.volume = Int32(volume)
            volumeSlider?.doubleValue = Double(volume)
            volumeButton?.image = NSImage(systemSymbolName: volumeSymbol(for: volume),
                                          accessibilityDescription: "Volume")
        }

        private func volumeSymbol(for v: Int) -> String {
            switch v {
            case 0: return "speaker.slash.fill"
            case 1...33: return "speaker.wave.1.fill"
            case 34...66: return "speaker.wave.2.fill"
            default: return "speaker.wave.3.fill"
            }
        }

        // MARK: VLCMediaPlayerDelegate

        func mediaPlayerStateChanged(_ aNotification: Notification) {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.updatePlayButton()
                // libVLC resets / lazily initialises the audio output around
                // play state changes; re-applying the user's volume keeps it
                // sticky across loads and pause/resume.
                self.applyVolume()
            }
        }

        func mediaPlayerTimeChanged(_ aNotification: Notification) {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if !self.isUserSeeking {
                    self.slider?.doubleValue = Double(self.player.position)
                }
                self.timeLabel?.stringValue = self.player.time.stringValue
            }
        }
    }
}

#endif
