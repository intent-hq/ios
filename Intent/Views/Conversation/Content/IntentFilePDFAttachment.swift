import SwiftUI
import Textual

struct IntentFilePDFAttachment: Attachment {
    let pdf: WorkspacePDF

    var description: String { String(localized: "PDF: \(pdf.name), \(pdf.pageCount) pages") }

    var body: some View {
        VStack(spacing: Constants.Conversation.ImagePlaceholder.failureLabelSpacing) {
            Image(uiImage: pdf.thumbnail)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityHidden(true)
            Text(pdf.name)
                .lineLimit(1)
                .truncationMode(.middle)
            Text("\(pdf.pageCount) pages")
                .foregroundStyle(.secondary)
        }
        .interFont(Constants.Typography.subtextXXS)
        .padding(Constants.Conversation.ImageThumbnail.cornerRadius)
        // Textual draws an ideal-sized symbol into the square run bounds.
        .frame(width: SquareImageThumbnail.transcriptSide, height: SquareImageThumbnail.transcriptSide)
        .background(.background, in: .rect(cornerRadius: Constants.Conversation.ImageThumbnail.cornerRadius))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("PDF: \(pdf.name), \(pdf.pageCount) pages")
        .accessibilityHint("Open PDF full screen")
        .accessibilityAddTraits(.isButton)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, in _: TextEnvironmentValues) -> CGSize {
        IntentFileImageAttachment.thumbnailSize(proposedWidth: proposal.width)
    }
}

struct IntentFilePDFFailureAttachment: Attachment {
    let name: String
    let workspaceId: String?
    let path: String

    var description: String { String(localized: "PDF unavailable: \(name)") }

    var body: some View {
        VStack(spacing: Constants.Conversation.ImagePlaceholder.failureLabelSpacing) {
            Label("PDF", systemImage: "doc.richtext")
            Text(name)
                .lineLimit(2)
                .truncationMode(.middle)
            if workspaceId != nil {
                Text("Tap to retry")
            }
        }
        .interFont(Constants.Typography.subtextXXS)
        .foregroundStyle(.secondary)
        .frame(width: SquareImageThumbnail.transcriptSide, height: SquareImageThumbnail.transcriptSide)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("PDF unavailable: \(name)")
        .accessibilityHint("Retries loading the PDF", isEnabled: workspaceId != nil)
        .accessibilityAddTraits(workspaceId == nil ? [] : .isButton)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, in _: TextEnvironmentValues) -> CGSize {
        IntentFileImageAttachment.thumbnailSize(proposedWidth: proposal.width)
    }

    @MainActor
    func prepareRetry(using loader: WorkspaceFileImageLoader) -> Bool {
        guard let workspaceId else { return false }
        loader.forgetFailure(workspaceId: workspaceId, path: path)
        return true
    }
}
