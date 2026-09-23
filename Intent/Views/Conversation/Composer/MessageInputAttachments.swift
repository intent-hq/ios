import SwiftUI

extension MessageInputView {
    @ViewBuilder
    var pendingImagesRow: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Constants.Conversation.Composer.pendingImageRowSpacing) {
                ForEach(Array(viewModel.pendingImages.enumerated()), id: \.offset) { index, image in
                    pendingImage(image, index: index)
                }
            }
            .padding(.horizontal, Constants.Conversation.Composer.pendingImagesHorizontalPadding)
            .padding(.top, Constants.Conversation.Composer.pendingImagesTopPadding)
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder
    var pendingFilesRow: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Constants.Conversation.Composer.pendingFileRowSpacing) {
                ForEach(Array(viewModel.pendingFiles.enumerated()), id: \.element.id) { index, file in
                    pendingFile(file, index: index)
                }
            }
            .padding(.horizontal, Constants.Conversation.Composer.pendingFilesHorizontalPadding)
            .padding(.top, Constants.Conversation.Composer.pendingFilesTopPadding)
        }
        .scrollIndicators(.hidden)
    }

    private func pendingImage(_ image: UIImage, index: Int) -> some View {
        ZStack(alignment: .topTrailing) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .accessibilityLabel("Attached image \(index + 1)")
                .frame(
                    width: Constants.Conversation.Composer.pendingImageSide,
                    height: Constants.Conversation.Composer.pendingImageSide
                )
                .clipShape(RoundedRectangle(cornerRadius: Constants.Conversation.Composer.pendingImageCornerRadius))
            Button {
                viewModel.removeImage(at: index)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.white)
                    .background(Circle().fill(.black.opacity(
                        Constants.Conversation.Composer.imageRemoveButtonBackgroundOpacity
                    )))
                    .frame(
                        minWidth: Constants.Conversation.Composer.controlTarget,
                        minHeight: Constants.Conversation.Composer.controlTarget,
                        alignment: .topTrailing
                    )
                    .contentShape(Rectangle())
            }
            .offset(
                x: Constants.Conversation.Composer.pendingImageRemoveButtonHorizontalOffset,
                y: Constants.Conversation.Composer.pendingImageRemoveButtonVerticalOffset
            )
            .accessibilityLabel("Remove image \(index + 1)")
        }
    }

    private func pendingFile(_ file: PendingFile, index: Int) -> some View {
        HStack(spacing: Constants.Conversation.Composer.pendingFileContentSpacing) {
            if let progress = viewModel.fileUploadProgress[file.id] {
                uploadingFileContent(file, progress: progress)
            } else {
                pendingFileContent(file)
                Button {
                    viewModel.removePendingFile(at: index)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                        .contentShape(Rectangle().inset(
                            by: -Constants.Conversation.Composer.controlTarget / 2
                        ))
                }
                .accessibilityLabel("Remove \(file.displayName)")
            }
        }
        .padding(.horizontal, Constants.Conversation.Composer.pendingFileHorizontalPadding)
        .padding(.vertical, Constants.Conversation.Composer.pendingFileVerticalPadding)
        .frame(maxWidth: Constants.Conversation.Composer.pendingFileMaximumWidth)
        .background(Theme.muted(for: colorScheme).opacity(Constants.Conversation.Composer.pendingFileBackgroundOpacity))
        .clipShape(RoundedRectangle(cornerRadius: Constants.Conversation.Composer.pendingFileCornerRadius))
    }

    @ViewBuilder
    private func uploadingFileContent(_ file: PendingFile, progress: Double) -> some View {
        ProgressView()
            .controlSize(.small)
        VStack(alignment: .leading, spacing: 0) {
            Text(file.displayName)
                .font(.caption)
                .lineLimit(1)
            Text(progress > 0 && progress < 1
                 ? "Uploading… \(Int(progress * 100))%"
                 : "Uploading…")
                .font(.caption2)
                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
        }
    }

    @ViewBuilder
    private func pendingFileContent(_ file: PendingFile) -> some View {
        Image(systemName: "doc.fill")
            .font(.caption)
            .foregroundStyle(Theme.mutedForeground(for: colorScheme))
            .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 0) {
            Text(file.displayName)
                .font(.caption)
                .lineLimit(1)
            if let formattedSize = file.formattedSize {
                Text(formattedSize)
                    .font(.caption2)
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
            }
        }
    }
}
