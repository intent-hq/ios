import SwiftUI

/// User-attached video: a poster until tapped, a retry for failed fetches,
/// or the caller's file chip when the format cannot be played.
struct AttachmentReferenceVideoView<Fallback: View>: View {
    let workspaceId: String
    let attachmentId: String?
    let name: String
    let mimeType: String?
    let fallback: Fallback
    @Environment(BackendSession.self) private var session: BackendSession?
    @Environment(\.colorScheme) private var colorScheme
    @State private var video: WorkspaceVideo?
    @State private var failed = false
    @State private var unsupported = false
    @State private var attempt = 0
    @State private var loadedKey: [String] = []
    @State private var lightboxPresented = false
    @ScaledMetric(relativeTo: .caption) private var retryIconSide: CGFloat = 12
    private let playBackdropOpacity = 0.6

    private var loadKey: [String] { [workspaceId, attachmentId ?? "", mimeType ?? ""] }

    var body: some View {
        content
            .task(id: loadKey + [String(attempt)]) {
                await loadVideo()
            }
    }

    @ViewBuilder
    private var content: some View {
        if attachmentId == nil || unsupported {
            fallback
        } else if let video, loadedKey == loadKey {
            Button { lightboxPresented = true } label: {
                SquareImageThumbnail(image: video.poster, side: ImageAttachmentThumbnail.side)
                    .overlay {
                        Image(systemName: "play.circle.fill")
                            .font(.largeTitle)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(playBackdropOpacity))
                            .accessibilityHidden(true)
                    }
                    .copyContextMenuPassthrough()
            }
            .buttonStyle(IntentContentButtonStyle())
            .accessibilityLabel("Video: \(name)")
            .accessibilityHint("Play full screen")
            .fullScreenCover(isPresented: $lightboxPresented) {
                VideoLightboxView(video: video)
                    .coversConversationComposers()
            }
        } else if failed {
            Button { attempt += 1 } label: {
                placeholder {
                    Image(.clockwiseArrow)
                        .resizable()
                        .scaledToFit()
                        .frame(width: retryIconSide, height: retryIconSide)
                        .accessibilityHidden(true)
                }
                .copyContextMenuPassthrough()
            }
            .buttonStyle(IntentContentButtonStyle())
            .accessibilityLabel("Retry loading video: \(name)")
        } else {
            placeholder {
                ProgressView()
                    .controlSize(.mini)
            }
            .accessibilityLabel("Loading video: \(name)")
        }
    }

    private func loadVideo() async {
        guard let attachmentId else { return }
        let key = loadKey
        if loadedKey != key { video = nil }
        guard video == nil else { return }
        failed = false
        unsupported = false
        let loader = session?.attachmentImageLoader ?? .shared
        do {
            let loaded = attempt == 0
                ? try await loader.video(workspaceId: workspaceId, attachmentId: attachmentId, mimeType: mimeType)
                : try await loader.retryVideo(workspaceId: workspaceId, attachmentId: attachmentId, mimeType: mimeType)
            // Shared cached fetches can finish after SwiftUI cancels this row's task.
            try Task.checkCancellation()
            video = loaded
            loadedKey = key
        } catch is CancellationError {
            // Scrolling away is not a failed download.
        } catch {
            guard !Task.isCancelled else { return }
            if error as? WorkspaceFileImageLoader.LoadError == .notAVideo {
                unsupported = true
            } else {
                failed = true
            }
        }
    }

    private func placeholder<Content: View>(@ViewBuilder _ label: () -> Content) -> some View {
        VStack(spacing: Constants.Conversation.ImagePlaceholder.loadingLabelSpacing) { label() }
            .font(.caption)
            .frame(width: ImageAttachmentThumbnail.side, height: ImageAttachmentThumbnail.side)
            .foregroundStyle(Theme.mutedForeground(for: colorScheme))
            .background(Theme.muted(for: colorScheme).opacity(Constants.Conversation.ImagePlaceholder.backgroundOpacity))
            .clipShape(.rect(cornerRadius: Constants.Conversation.ImageThumbnail.cornerRadius))
    }
}
