import AVFoundation
import SwiftUI

/// A decorative, silent player whose lifetime is bounded by the dark splash.
struct SplashVideoBackground: UIViewRepresentable {
    let isPlaying: Bool

    func makeUIView(context _: Context) -> SplashVideoView {
        SplashVideoView(url: Bundle.main.url(forResource: "bg_intro_dark", withExtension: "mp4"))
    }

    func updateUIView(_ view: SplashVideoView, context _: Context) {
        view.setPlaying(isPlaying)
    }

    static func dismantleUIView(_ view: SplashVideoView, coordinator _: Void) {
        view.stop()
    }
}

final class SplashVideoView: UIView {
    let playerLayer = AVPlayerLayer()
    private(set) var loadingTask: Task<Void, Never>?
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var observations: [NSKeyValueObservation] = []
    private var isPlaying = false

    init(url: URL?) {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        playerLayer.videoGravity = .resizeAspectFill
        layer.addSublayer(playerLayer)
        clipsToBounds = true
        guard let url else { return }
        loadingTask = Task { [weak self] in
            do {
                let asset = AVURLAsset(url: url)
                let (playable, duration) = try await asset.load(.isPlayable, .duration)
                // AVPlayerLooper raises an ObjC exception for a zero-duration item.
                guard !Task.isCancelled, playable, duration.seconds.isFinite, duration.seconds > 0 else { return }
                self?.preparePlayer(asset: asset)
            } catch {
                // The transparent layer leaves the solid theme background visible.
            }
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }

    func setPlaying(_ playing: Bool) {
        guard isPlaying != playing else { return }
        isPlaying = playing
        updatePlayback()
    }

    func stop() {
        loadingTask?.cancel()
        loadingTask = nil
        observations.removeAll()
        player?.pause()
        looper?.disableLooping()
        looper = nil
        playerLayer.player = nil
        player?.removeAllItems()
        player = nil
    }

    private func preparePlayer(asset: AVURLAsset) {
        let player = AVQueuePlayer()
        player.isMuted = true
        // Do not acquire a MediaAudioSession lease or alter the user's audio session.
        let looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(asset: asset))
        self.player = player
        self.looper = looper
        playerLayer.player = player
        observations = [
            player.observe(\.status, options: [.initial, .new]) { @Sendable [weak self] _, _ in
                Task { @MainActor [weak self] in self?.handlePlaybackFailure() }
            },
            looper.observe(\.status, options: [.initial, .new]) { @Sendable [weak self] _, _ in
                Task { @MainActor [weak self] in self?.handlePlaybackFailure() }
            }
        ]
        updatePlayback()
    }

    private func updatePlayback() {
        if isPlaying {
            player?.play()
        } else {
            player?.pause()
            // Seek while paused so Reduce Motion and inactive scenes show frame one.
            player?.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    private func handlePlaybackFailure() {
        if player?.status == .failed || looper?.status == .failed {
            stop()
        }
    }
}
