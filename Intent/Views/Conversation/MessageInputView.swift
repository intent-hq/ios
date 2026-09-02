import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct MessageInputView: View {
    @Bindable var viewModel: ConversationViewModel
    private let store: ConversationStore
    @Environment(\.colorScheme) var colorScheme

    @State private var isFocused: Bool = false
    @State private var textViewHeight: CGFloat = Constants.Conversation.Composer.minimumTextViewHeight
    @State private var isPhotoPickerPresented: Bool = false
    @State private var isFilePickerPresented: Bool = false

    // Local text state to decouple TextField from viewModel updates.
    // This prevents typing lag when the viewModel is rapidly updating
    // during streaming (every legacy-store publication triggers a re-render).
    @State private var localText: String = ""

    init(viewModel: ConversationViewModel, store: ConversationStore) {
        self.viewModel = viewModel
        self.store = store
    }

    var body: some View {
        VStack(spacing: 0) {
            // Pending image thumbnails
            if !viewModel.pendingImages.isEmpty {
                pendingImagesRow
            }

            // Pending file chips
            if !viewModel.pendingFiles.isEmpty {
                pendingFilesRow
            }

            // Input row
            HStack(alignment: .center, spacing: 8) {
                // Left button: photo picker or stop button
                if store.isStreaming {
                    // Stop button replaces photo picker during streaming
                    Button {
                        HapticManager.impact(.light)
                        Task { await viewModel.stopStreaming() }
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.title2)
                            .foregroundStyle(Theme.destructive(for: colorScheme))
                            .frame(
                                minWidth: Constants.Accessibility.minimumTapTarget,
                                minHeight: Constants.Accessibility.minimumTapTarget)
                    }
                    .accessibilityLabel("Stop response")
                } else {
                    // Attach menu: photos or arbitrary files (only when not streaming)
                    Menu {
                        Button {
                            isPhotoPickerPresented = true
                        } label: {
                            Label("Photos", systemImage: "photo.on.rectangle")
                        }
                        Button {
                            isFilePickerPresented = true
                        } label: {
                            Label("Files", systemImage: "folder")
                        }
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title2)
                            .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                            .frame(
                                minWidth: Constants.Accessibility.minimumTapTarget,
                                minHeight: Constants.Accessibility.minimumTapTarget)
                    }
                    .accessibilityLabel("Add attachment")
                }

                // Text editor — bound to localText to avoid lag during streaming
                // Uses SubmittableTextView so hardware Enter sends, Shift+Enter inserts newline
                ZStack(alignment: .topLeading) {
                    SubmittableTextView(
                        text: $localText,
                        isFocused: $isFocused,
                        onSubmit: { sendCurrentMessage() },
                        onHeightChange: { newHeight in
                            textViewHeight = min(
                                max(newHeight, Constants.Conversation.Composer.minimumTextViewHeight),
                                Constants.Conversation.Composer.maximumTextViewHeight)
                        }
                    )
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .frame(height: textViewHeight)

                    // Placeholder (UITextView has no built-in placeholder)
                    if localText.isEmpty {
                        Text("Message...")
                            .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                            .font(.body)
                            .padding(.horizontal, 17)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                }
                .background(Theme.muted(for: colorScheme).opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 18))

                // Send button (right side)
                VStack(spacing: 4) {
                    // Send stays disabled while a send is already placing
                    // files (pendingFiles clears only after success, so a
                    // second tap would re-upload them).
                    let hasContent = (!localText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || viewModel.hasPendingAttachments)
                        && !viewModel.isUploadingFiles

                    if !store.isStreaming || hasContent {
                        Button {
                            sendCurrentMessage()
                        } label: {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.title2)
                                .foregroundStyle(
                                    hasContent
                                        ? Theme.primary(for: colorScheme)
                                        : Theme.mutedForeground(for: colorScheme)
                                )
                                .frame(
                                    minWidth: Constants.Accessibility.minimumTapTarget,
                                    minHeight: Constants.Accessibility.minimumTapTarget)
                        }
                        .disabled(!hasContent)
                        .accessibilityLabel("Send message")
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(Theme.card(for: colorScheme))
        .photosPicker(
            isPresented: $isPhotoPickerPresented,
            selection: $viewModel.selectedPhotoItems,
            maxSelectionCount: Constants.Conversation.Composer.maximumImageSelectionCount,
            matching: .images
        )
        .onChange(of: viewModel.selectedPhotoItems) { _, _ in
            Task { await viewModel.loadSelectedPhotos() }
        }
        .fileImporter(
            isPresented: $isFilePickerPresented,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                viewModel.addFiles(urls)
            }
        }
        .onAppear {
            localText = viewModel.messageText
        }
        .onChange(of: localText) { _, newValue in
            // Push local edits to viewModel (for draft persistence)
            viewModel.messageText = newValue
        }
        .onChange(of: viewModel.messageText) { _, newValue in
            // Pull viewModel changes (e.g. cleared after send, draft restore)
            if newValue != localText {
                localText = newValue
            }
        }
    }

    // MARK: - Pending images

    @ViewBuilder
    private var pendingImagesRow: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(Array(viewModel.pendingImages.enumerated()), id: \.offset) { index, image in
                    ZStack(alignment: .topTrailing) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(
                                width: Constants.Conversation.Composer.pendingImageSide,
                                height: Constants.Conversation.Composer.pendingImageSide)
                            .clipShape(RoundedRectangle(cornerRadius: 8))

                        Button {
                            viewModel.removeImage(at: index)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.white)
                                .background(Circle().fill(.black.opacity(0.5)))
                                .frame(
                                    minWidth: Constants.Accessibility.minimumTapTarget,
                                    minHeight: Constants.Accessibility.minimumTapTarget)
                        }
                        .offset(x: 4, y: -4)
                        .accessibilityLabel("Remove image \(index + 1)")
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
        }
        .scrollIndicators(.hidden)
    }

    // MARK: - Pending files

    @ViewBuilder
    private var pendingFilesRow: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(Array(viewModel.pendingFiles.enumerated()), id: \.element.id) { index, file in
                    HStack(spacing: 6) {
                        // Upload in flight (send-time placement): spinner
                        // replaces the doc icon; chunked (> 25 MB) uploads
                        // show fractional progress under the name.
                        if let progress = viewModel.fileUploadProgress[file.id] {
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
                        } else {
                            Image(systemName: "doc.fill")
                                .font(.caption)
                                .foregroundStyle(Theme.mutedForeground(for: colorScheme))

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

                            Button {
                                viewModel.removePendingFile(at: index)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                                    .frame(
                                        minWidth: Constants.Accessibility.minimumTapTarget,
                                        minHeight: Constants.Accessibility.minimumTapTarget)
                            }
                            .accessibilityLabel("Remove \(file.displayName)")
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .frame(maxWidth: Constants.Conversation.Composer.pendingFileMaximumWidth)
                    .background(Theme.muted(for: colorScheme).opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
        }
        .scrollIndicators(.hidden)
    }

    // MARK: - Actions

    private func sendCurrentMessage() {
        // Check if dictation is active — only resign focus if so.
        // This prevents keyboard users from seeing a focus flicker.
        let isDictating = UITextInputMode.activeInputModes.contains { $0.primaryLanguage == "dictation" }

        if isDictating {
            // Resign focus to stop dictation and commit final text
            isFocused = false
        }

        // Defer to next run loop to let dictation finalize (if it was active)
        DispatchQueue.main.async {
            // The visible send button disables while a send is placing
            // files, but the text view's submit callback still lands here —
            // pendingFiles clears only after success, so a second send
            // would duplicate the uploads.
            guard !viewModel.isUploadingFiles else { return }
            let text = localText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty || viewModel.hasPendingAttachments else {
                isFocused = true
                return
            }
            HapticManager.impact(.medium)
            // Capture images before clearing so they're available for the async send
            let imagesToSend = viewModel.pendingImages
            localText = ""
            viewModel.pendingImages.removeAll()
            // Re-focus after clearing
            DispatchQueue.main.asyncAfter(deadline: .now() + Constants.Conversation.Composer.refocusDelay) {
                isFocused = true
            }
            Task { await viewModel.sendMessage(text, images: imagesToSend) }
        }
    }
}

