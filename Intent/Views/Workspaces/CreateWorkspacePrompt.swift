import PhotosUI
import SwiftUI

struct CreateWorkspacePrompt: View {
    @Binding var text: String
    @Bindable var attachments: WorkspaceCreationImages
    let focus: WorkspacePromptFocus
    @State private var showsPhotos = false
    @State private var showsFiles = false
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: CreateWorkspaceFormStyle.rowSpacing) {
            WorkspaceCreationPromptEditor(text: $text, attachments: attachments, focus: focus)
            if !attachments.images.isEmpty {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(attachments.images) { image in
                            WorkspaceCreationImagePreview(image: image) { attachments.remove(image.id) }
                        }
                    }
                }
            }
            HStack {
                WorkspaceAttachmentMenu(
                    onPhotos: { showsPhotos = true },
                    onFiles: { showsFiles = true },
                    glyphAlignment: .bottomLeading
                )
                .disabled(attachments.isImporting || attachments.remainingCount == 0)
                if attachments.isImporting {
                    ProgressView("Preparing images…")
                        .interFont(Constants.Typography.bodyXS)
                }
                Spacer(minLength: 0)
            }
            if let error = attachments.errorMessage {
                Text(error)
                    .interFont(Constants.Typography.bodyXS)
                    .foregroundStyle(Theme.destructive(for: colorScheme))
                    .accessibilityIdentifier("creation.imageError")
            }
        }
        .padding(CreateWorkspaceFormStyle.pagePadding)
        .background(CreateWorkspaceFormStyle.card(for: colorScheme), in: .rect(
            cornerRadius: CreateWorkspaceFormStyle.cornerRadius
        ))
        .photosPicker(
            isPresented: $showsPhotos,
            selection: $selectedPhotos,
            maxSelectionCount: max(1, attachments.remainingCount),
            matching: .images
        )
        .onChange(of: selectedPhotos) { _, items in
            attachments.addPhotos(items)
            selectedPhotos = []
        }
        .fileImporter(isPresented: $showsFiles, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
            attachments.addFiles(result)
        }
    }
}

private struct WorkspaceCreationPromptEditor: View {
    @Binding var text: String
    let attachments: WorkspaceCreationImages
    let focus: WorkspacePromptFocus
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @ScaledMetric(relativeTo: .body) private var bodyTracking = CreateWorkspaceFormStyle.bodyTracking

    private var minimumEditorHeight: CGFloat {
        CreateWorkspaceFormStyle.promptHeight - CreateWorkspaceFormStyle.pagePadding * 2
            - CreateWorkspaceFormStyle.attachmentTarget - CreateWorkspaceFormStyle.rowSpacing
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            WorkspacePromptTextView(
                text: $text,
                minimumHeight: minimumEditorHeight,
                allowsImagePaste: !attachments.isImporting,
                onPasteImages: attachments.addPaste,
                focus: focus
            )
            if text.isEmpty {
                Text("What should we work on?")
                    .interFont(Constants.Typography.bodyS)
                    .tracking(bodyTracking)
                    .foregroundStyle(CreateWorkspaceFormStyle.secondary(for: colorScheme, contrast: contrast))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}

private struct WorkspaceCreationImagePreview: View {
    let image: WorkspaceCreationImages.Image
    let onRemove: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @ScaledMetric(relativeTo: .body) private var removeIconSize: CGFloat = 17
    private let previewSide: CGFloat = 72
    private let removeTarget: CGFloat = 44

    var body: some View {
        VStack(spacing: 0) {
            Image(uiImage: image.preview)
                .resizable()
                .scaledToFill()
                .frame(width: previewSide, height: previewSide)
                .clipShape(.rect(cornerRadius: CreateWorkspaceFormStyle.rowSpacing))
                .accessibilityLabel("Attached image")
            Button(action: onRemove) {
                Image(.closeCircle)
                    .resizable()
                    .scaledToFit()
                    .frame(width: removeIconSize, height: removeIconSize)
                    .frame(minWidth: removeTarget, minHeight: removeTarget)
            }
            .buttonStyle(IntentContentButtonStyle())
            .opacity(isEnabled ? 1 : Constants.ConnectionSheet.placeholderOpacity)
            .accessibilityLabel("Remove image")
            .accessibilityIdentifier("creation.removeImage")
        }
    }
}
