import SwiftUI

/// One selection shared by every step, separate from the conversation composer.
struct QuestionAttachmentTray: View {
    let attachments: ConversationAttachmentPipeline
    @Environment(\.colorScheme) private var colorScheme

    private typealias Layout = Constants.Conversation.Composer

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.pendingFileRowSpacing) {
            if attachments.isLoadingPhotos {
                ProgressView("Loading attachments…")
            }
            if attachments.hasPendingAttachments {
                ScrollView(.horizontal) {
                    HStack(spacing: Layout.pendingImageRowSpacing) {
                        // These stateless previews mirror the composer's index-based
                        // image selection; equal images may be attached twice.
                        ForEach(Array(attachments.pendingImages.enumerated()), id: \.offset) { index, image in
                            imagePreview(image, index: index)
                        }
                        ForEach(Array(attachments.pendingFiles.enumerated()), id: \.element.id) { index, file in
                            filePreview(file, index: index)
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .accessibilityIdentifier("question.attachments")
            }
            if let error = attachments.imagePlacementError ?? attachments.filePlacementError {
                Text(error)
                    .interFont(Constants.Typography.bodyXS)
                    .foregroundStyle(Theme.destructive(for: colorScheme))
                    .accessibilityIdentifier("question.attachment.error")
            }
        }
        .padding(.horizontal, Layout.pendingImagesHorizontalPadding)
        .padding(.top, attachments.hasPendingAttachments || attachments.isLoadingPhotos ? Layout.pendingImagesTopPadding : 0)
    }

    private func imagePreview(_ image: UIImage, index: Int) -> some View {
        ZStack(alignment: .topTrailing) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: Layout.pendingImageSide, height: Layout.pendingImageSide)
                .clipShape(.rect(cornerRadius: Layout.pendingImageCornerRadius))
                .accessibilityLabel("Attached image \(index + 1)")
            Button { attachments.removeImage(at: index) } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.white, .black)
                    .frame(minWidth: Layout.controlTarget, minHeight: Layout.controlTarget)
                    .contentShape(.rect)
            }
            .buttonStyle(IntentContentButtonStyle())
            .accessibilityLabel("Remove image \(index + 1)")
            .accessibilityIdentifier("question.removeImage")
        }
    }

    private func filePreview(_ file: PendingFile, index: Int) -> some View {
        HStack(spacing: Layout.pendingFileContentSpacing) {
            Image(systemName: file.video == nil ? "doc" : "video")
                .accessibilityHidden(true)
            VStack(alignment: .leading) {
                Text(file.displayName).lineLimit(1)
                if let progress = attachments.fileUploadProgress[file.id] {
                    ProgressView(value: progress) { Text("Uploading…") }
                } else if let size = file.formattedSize {
                    Text(size).foregroundStyle(Theme.mutedForeground(for: colorScheme))
                }
            }
            Button { attachments.removePendingFile(at: index) } label: {
                Image(systemName: "xmark.circle.fill")
                    .frame(minWidth: Layout.controlTarget, minHeight: Layout.controlTarget)
                    .contentShape(.rect)
            }
            .buttonStyle(IntentContentButtonStyle())
            .accessibilityLabel("Remove \(file.displayName)")
            .accessibilityIdentifier("question.removeFile")
        }
        .interFont(Constants.Typography.subtextXXS)
        .padding(.horizontal, Layout.pendingFileHorizontalPadding)
        .padding(.vertical, Layout.pendingFileVerticalPadding)
        .frame(maxWidth: Layout.pendingFileMaximumWidth)
        .background(Theme.muted(for: colorScheme), in: .rect(cornerRadius: Layout.pendingFileCornerRadius))
    }
}
