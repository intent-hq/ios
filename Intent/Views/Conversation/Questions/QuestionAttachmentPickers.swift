import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct QuestionAttachmentPickers: ViewModifier {
    @Bindable var attachments: ConversationAttachmentPipeline
    let workspaceId: String
    @Binding var showsPhotos: Bool
    @Binding var showsFiles: Bool

    func body(content: Content) -> some View {
        content
            .photosPicker(
                isPresented: $showsPhotos,
                selection: $attachments.selectedPhotoItems,
                maxSelectionCount: max(1, attachments.remainingPhotoImageCount ?? Constants.Conversation.Composer.maximumImageSelectionCount),
                matching: .images
            )
            .onChange(of: attachments.selectedPhotoItems) { _, _ in
                attachments.startLoadingSelectedPhotos(workspaceId: workspaceId)
            }
            .fileImporter(isPresented: $showsFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls): attachments.addFiles(urls)
                case .failure(let error): attachments.filePlacementError = error.localizedDescription
                }
            }
    }
}
