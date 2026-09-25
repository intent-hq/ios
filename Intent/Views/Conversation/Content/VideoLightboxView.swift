import AVKit
import SwiftUI

struct VideoLightboxView: View {
    /// Retain the file independently of the transcript's attachment/cache.
    let video: WorkspaceVideo
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?

    var body: some View {
        VideoPlayer(player: player)
            .background(.black)
            .safeAreaInset(edge: .top, alignment: .trailing) {
                Button("Close video", systemImage: "xmark") { dismiss() }
                    .labelStyle(.iconOnly)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(Constants.Conversation.ImageLightbox.actionButtonPadding)
                    .background(.black, in: Circle())
                    .padding(Constants.Conversation.ImageLightbox.actionContainerPadding)
            }
            .onAppear {
                let player = AVPlayer(url: video.url)
                self.player = player
                player.play()
            }
            .onDisappear {
                player?.pause()
                player?.replaceCurrentItem(with: nil)
                player = nil
            }
    }
}
