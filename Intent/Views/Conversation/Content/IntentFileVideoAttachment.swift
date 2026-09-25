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
    let name: String

    var description: String { "Video: \(name)" }

    var body: some View {
        VStack(spacing: Constants.Conversation.ImagePlaceholder.failureLabelSpacing) {
            Label("Video", systemImage: "video")
            Text(name).lineLimit(2).truncationMode(.middle)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Video: \(name)")
        .accessibilityHint("Video unavailable")
    }

    func sizeThatFits(_ proposal: ProposedViewSize, in _: TextEnvironmentValues) -> CGSize {
        IntentFileImageAttachment.thumbnailSize(proposedWidth: proposal.width)
    }
}
