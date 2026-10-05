import AVKit
import SwiftUI

struct VideoLightboxView: View {
    /// Retain the file independently of the transcript's attachment/cache.
    let video: WorkspaceVideo
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var audioLease: UUID?
    @State private var playbackFailed = false
    @State private var isClosing = false
    @ScaledMetric(relativeTo: .body) private var closeIconSide: CGFloat = 17

    var body: some View {
        VideoPlayer(player: player)
            .background(.black)
            .safeAreaInset(edge: .top, alignment: .trailing) {
                Button(action: close) {
                    Image(.close)
                        .resizable()
                        .scaledToFit()
                        .frame(width: closeIconSide, height: closeIconSide)
                        .foregroundStyle(.white)
                        .padding(Constants.Conversation.ImageLightbox.actionButtonPadding)
                        .background(.black, in: Circle())
                        .frame(
                            minWidth: Constants.Accessibility.minimumTapTarget,
                            minHeight: Constants.Accessibility.minimumTapTarget
                        )
                        .contentShape(.rect)
                }
                .buttonStyle(IntentContentButtonStyle())
                .accessibilityLabel("Close video")
                .padding(Constants.Conversation.ImageLightbox.actionContainerPadding)
            }
            .accessibilityAction(.escape, close)
            .task { await startPlayback() }
            .onDisappear {
                player?.pause()
                player?.replaceCurrentItem(with: nil)
                player = nil
                if let lease = audioLease {
                    audioLease = nil
                    Task { try? await MediaAudioSession.shared.release(lease) }
                }
            }
            .alert("Could not start video playback", isPresented: $playbackFailed) {
                Button("Close", role: .cancel, action: close)
            }
    }

    private func close() {
        isClosing = true
        player?.pause()
        dismiss()
    }

    private func startPlayback() async {
        do {
            let lease = try await MediaAudioSession.shared.acquire(.playback)
            // Dismissal may cancel this task while activation is blocking. Do
            // not create a player after disappearance, or leak that activation.
            guard !Task.isCancelled, !isClosing else {
                try? await MediaAudioSession.shared.release(lease)
                return
            }
            audioLease = lease
            let player = AVPlayer(url: video.url)
            self.player = player
            player.play()
        } catch {
            if !Task.isCancelled, !isClosing { playbackFailed = true }
        }
    }
}
