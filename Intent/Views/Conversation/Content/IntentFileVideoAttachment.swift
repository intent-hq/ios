import SwiftUI
import Textual

struct IntentFileVideoAttachment: Attachment {
    let video: WorkspaceVideo
    let name: String
    private static let playBackdropOpacity = 0.6

    var description: String { "Video: \(name)" }

    var body: some View {
        Color.clear
            .overlay {
                Image(uiImage: video.poster)
                    .resizable()
                    .scaledToFill()
            }
            .clipShape(.rect(cornerRadius: Constants.Conversation.ImageThumbnail.cornerRadius))
            .overlay {
                Image(systemName: "play.circle.fill")
                    .font(.largeTitle)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(Self.playBackdropOpacity))
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Video: \(name)")
            .accessibilityHint("Play full screen")
            .accessibilityAddTraits(.isButton)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, in _: TextEnvironmentValues) -> CGSize {
        IntentFileImageAttachment.thumbnailSize(proposedWidth: proposal.width)
    }
}

struct IntentFileVideoFailureAttachment: Attachment {
    nonisolated enum RetrySource: Hashable, Sendable {
        case asset(workspaceId: String, assetId: String)
        case file(workspaceId: String, path: String)
    }

    let name: String
    let retrySource: RetrySource?

    init(name: String, retrySource: RetrySource? = nil) {
        self.name = name
        self.retrySource = retrySource
    }

    var description: String { "Video: \(name)" }

    var body: some View {
        VStack(spacing: Constants.Conversation.ImagePlaceholder.failureLabelSpacing) {
            Label("Video", systemImage: "video")
            Text(name).lineLimit(2).truncationMode(.middle)
            if retrySource != nil { Text("Tap to retry") }
        }
        .font(.caption)
        .lineLimit(1)
        .minimumScaleFactor(0.5)
        .foregroundStyle(.secondary)
        // Textual resolves an ideal-sized Canvas symbol, then scales it into
        // the square run bounds. Give it a square so the labels do not stretch.
        .frame(width: SquareImageThumbnail.transcriptSide, height: SquareImageThumbnail.transcriptSide)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Video unavailable: \(name)")
        .accessibilityHint("Retries loading the video", isEnabled: retrySource != nil)
        .accessibilityAddTraits(retrySource == nil ? [] : .isButton)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, in _: TextEnvironmentValues) -> CGSize {
        IntentFileImageAttachment.thumbnailSize(proposedWidth: proposal.width)
    }

    /// Textual renders attachment bodies as symbols; its tap handler owns retry.
    /// Clear the same session loader used to fetch, before re-resolving the markdown.
    @MainActor
    func prepareRetry(using loader: WorkspaceFileImageLoader) -> Bool {
        switch retrySource {
        case let .asset(workspaceId, assetId):
            loader.forgetAssetFailure(workspaceId: workspaceId, assetId: assetId)
        case let .file(workspaceId, path):
            loader.forgetFailure(workspaceId: workspaceId, path: path)
        case nil:
            return false
        }
        return true
    }
}
