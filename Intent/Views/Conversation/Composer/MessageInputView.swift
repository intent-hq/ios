import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct MessageInputView: View {
    @Bindable var viewModel: ConversationViewModel
    private let store: ConversationStore
    private let usesWorkspaceDesign: Bool
    private let onFocusChange: ((Bool) -> Void)?
    @Environment(\.colorScheme) var colorScheme

    @ScaledMetric(relativeTo: .title2) private var controlIconSide: CGFloat = 22
    @ScaledMetric(relativeTo: .caption) var attachmentIconSide: CGFloat = 12
    private let sendArrowScale: CGFloat = 0.75

    @State private var isFocused: Bool = false
    @State private var textViewHeight: CGFloat = Constants.Conversation.Composer.minimumTextViewHeight
    @State private var isPhotoPickerPresented: Bool = false
    @State private var isFilePickerPresented: Bool = false

    #if os(visionOS)
    @Environment(\.scenePhase) private var scenePhase
    @State private var dictation = SpeechDictationController()
    @State private var dictationSession: DictationSession?
    /// Last caret offset observed from the text view; `nil` until a selection
    /// change fires (a programmatically restored draft never fires one), which
    /// dictation treats as end-of-text.
    @State private var caretOffset: Int?
    #endif

    // Local text state to decouple TextField from viewModel updates.
    // This prevents typing lag when the viewModel is rapidly updating
    // during streaming (every legacy-store publication triggers a re-render).
    @State private var localText: String = ""

    init(
        viewModel: ConversationViewModel,
        store: ConversationStore,
        usesWorkspaceDesign: Bool = false,
        onFocusChange: ((Bool) -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.store = store
        self.usesWorkspaceDesign = usesWorkspaceDesign
        self.onFocusChange = onFocusChange
    }

    /// Overlay visibility is presentation policy, not permission to consume a
    /// draft. Read the live backend state again at both submission boundaries.
    var isConnectionReadyForSending: Bool { viewModel.connection.connectionState == .connected }

    var body: some View {
        VStack(spacing: 0) {
            supplementalRows
            if usesWorkspaceDesign {
                WorkspaceComposerRow(
                    text: $localText,
                    isFocused: $isFocused,
                    isStreaming: store.isStreaming,
                    hasAttachments: viewModel.hasPendingAttachments,
                    canSend: hasSendableContent,
                    onSend: sendCurrentMessage,
                    onStop: {
                        HapticManager.impact(.light)
                        Task { await viewModel.stopStreaming() }
                    },
                    onPhotos: { isPhotoPickerPresented = true },
                    onFiles: { isFilePickerPresented = true }
                )
            } else {
                inputRow
            }
        }
        .background {
            if usesWorkspaceDesign {
                RoundedRectangle(cornerRadius: workspaceCornerRadius)
                    .fill(Constants.Conversation.Design.Palette.surface(for: colorScheme))
            } else {
                Theme.card(for: colorScheme)
            }
        }
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
        .onChange(of: isFocused) { _, focused in
            onFocusChange?(focused)
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
        #if os(visionOS)
        .onDisappear {
            dictation.stop(reason: .viewDisappeared)
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase != .active {
                dictation.stop(reason: .sceneInactive)
            }
        }
        #endif
    }
}

private extension MessageInputView {
    var workspaceCornerRadius: CGFloat {
        let active = store.isStreaming || !localText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || viewModel.hasPendingAttachments
        return active ? Constants.Conversation.Design.Composer.activeCornerRadius : Constants.Conversation.Design.cornerRadius
    }

    @ViewBuilder
    var supplementalRows: some View {
        #if os(visionOS)
        if !viewModel.suggestedPrompts.isEmpty, !store.isStreaming {
            suggestedPromptChipsRow
        }
        if let hint = dictation.unavailabilityHint {
            dictationHintRow(hint)
        }
        #endif
        if !viewModel.pendingImages.isEmpty {
            pendingImagesRow
        }
        if !viewModel.pendingFiles.isEmpty {
            pendingFilesRow
        }
    }

    var inputRow: some View {
        HStack(alignment: .center, spacing: Constants.Conversation.Composer.inputRowSpacing) {
            leadingControl
            textEditor
            #if os(visionOS)
            dictationButton
            #endif
            sendButtonStack
        }
        .padding(.horizontal, Constants.Conversation.Composer.inputRowHorizontalPadding)
        .padding(.vertical, Constants.Conversation.Composer.inputRowVerticalPadding)
    }

    @ViewBuilder
    var leadingControl: some View {
        if store.isStreaming {
            stopButton
        } else {
            attachmentMenu
        }
    }

    var stopButton: some View {
        Button {
            HapticManager.impact(.light)
            Task { await viewModel.stopStreaming() }
        } label: {
            Image(.stopFill)
                .resizable()
                .scaledToFit()
                .frame(width: controlIconSide, height: controlIconSide)
                .foregroundStyle(Theme.destructive(for: colorScheme))
                .frame(
                    minWidth: Constants.Conversation.Composer.controlTarget,
                    minHeight: Constants.Conversation.Composer.controlTarget
                )
        }
        .accessibilityLabel("Stop response")
    }

    var attachmentMenu: some View {
        Menu {
            Button {
                isPhotoPickerPresented = true
            } label: {
                Label("Photos", systemImage: "photo.on.rectangle")
            }
            Button {
                isFilePickerPresented = true
            } label: {
                Label {
                    Text("Files")
                } icon: {
                    Image(.folder)
                }
            }
        } label: {
            Image(.addCircle)
                .resizable()
                .scaledToFit()
                .frame(width: controlIconSide, height: controlIconSide)
                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                .frame(
                    minWidth: Constants.Conversation.Composer.controlTarget,
                    minHeight: Constants.Conversation.Composer.controlTarget
                )
        }
        .accessibilityLabel("Add attachment")
    }

    var textEditor: some View {
        ZStack(alignment: .leading) {
            SubmittableTextView(
                text: $localText,
                isFocused: $isFocused,
                onSubmit: { sendCurrentMessage() },
                onHeightChange: updateTextViewHeight,
                onCaretChange: updateCaretOffset
            )
            .padding(.horizontal, Constants.Conversation.Composer.textEditorHorizontalPadding)
            .padding(.vertical, Constants.Conversation.Composer.fieldVerticalPadding)
            .frame(height: textViewHeight)
            if localText.isEmpty {
                Text("Message...")
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                    .interFont(Constants.Typography.bodyS)
                    .padding(.horizontal, Constants.Conversation.Composer.placeholderHorizontalPadding)
                    .padding(.vertical, Constants.Conversation.Composer.placeholderVerticalPadding)
                    .allowsHitTesting(false)
            }
        }
        .background(Theme.muted(for: colorScheme).opacity(Constants.Conversation.Composer.fieldBackgroundOpacity))
        .clipShape(RoundedRectangle(cornerRadius: Constants.Conversation.Composer.fieldCornerRadius))
    }

    var hasSendableContent: Bool {
        (!localText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || viewModel.hasPendingAttachments)
            && !viewModel.isUploadingFiles
            && isConnectionReadyForSending
    }

    private func updateTextViewHeight(_ naturalHeight: CGFloat) {
        textViewHeight = min(
            max(
                naturalHeight + Constants.Conversation.Composer.fieldVerticalPadding * 2,
                Constants.Conversation.Composer.minimumTextViewHeight
            ),
            Constants.Conversation.Composer.maximumTextViewHeight
        )
    }

    private func updateCaretOffset(_ offset: Int) {
        #if os(visionOS)
        caretOffset = offset
        #else
        _ = offset
        #endif
    }

    var sendButtonStack: some View {
        VStack(spacing: Constants.Conversation.Composer.sendButtonStackSpacing) {
            if !store.isStreaming || hasSendableContent {
                Button {
                    sendCurrentMessage()
                } label: {
                    Image(.arrowUp)
                        .resizable()
                        .scaledToFit()
                        .frame(width: controlIconSide * sendArrowScale, height: controlIconSide * sendArrowScale)
                        .foregroundStyle(Theme.card(for: colorScheme))
                        .frame(width: controlIconSide, height: controlIconSide)
                        .background {
                            Circle().fill(
                                hasSendableContent
                                    ? Theme.primary(for: colorScheme)
                                    : Theme.mutedForeground(for: colorScheme)
                            )
                        }
                        .frame(
                            minWidth: Constants.Conversation.Composer.controlTarget,
                            minHeight: Constants.Conversation.Composer.controlTarget
                        )
                }
                .disabled(!hasSendableContent)
                .accessibilityLabel("Send message")
            }
        }
    }
}

private extension MessageInputView {
    #if os(visionOS)
    // MARK: - visionOS dictation & suggested prompts

    /// Dictation toggle: starts a live Speech-framework session that inserts
    /// transcriptions at the caret; tapping again stops and keeps the final
    /// result.
    private var dictationButton: some View {
        Button {
            toggleDictation()
        } label: {
            Group {
                if dictation.isActive {
                    Image(.stopFill)
                        .resizable()
                        .scaledToFit()
                        .frame(width: controlIconSide, height: controlIconSide)
                } else {
                    Image(systemName: "mic.fill")
                        .font(.title2)
                }
            }
                .foregroundStyle(
                    dictation.isActive
                        ? Theme.destructive(for: colorScheme)
                        : Theme.primary(for: colorScheme)
                )
                .frame(
                    minWidth: Constants.Conversation.Composer.controlTarget,
                    minHeight: Constants.Conversation.Composer.controlTarget
                )
        }
        .accessibilityLabel(dictation.isActive ? "Stop dictation" : "Dictate")
    }

    private func toggleDictation() {
        HapticManager.impact(.light)
        // isActive covers the starting window too: a second tap while the
        // permission prompts are pending cancels the start before any audio.
        if dictation.isActive {
            dictation.stop(reason: .userTapped)
            return
        }

        dictationSession = DictationSession(baseText: localText, insertionOffset: caretOffset)
        dictation.onTranscriptChange = { transcription, endsSegment in
            guard var session = dictationSession else { return }
            switch session.apply(transcription: transcription, endsSegment: endsSegment, to: localText) {
            case .merged(let text):
                localText = text
                dictationSession = session
                if endsSegment {
                    // Programmatic text sets don't reliably fire a selection
                    // change, so the observed caret can be stale; track the
                    // committed insertion point so a re-tap after the
                    // recognizer finishes appends instead of replacing.
                    caretOffset = session.transcript.insertionOffset
                }
            case .diverged:
                // The composer text was edited outside dictation (typed, or
                // replaced by the view model — e.g. a send cleared it). The
                // edit wins: stop dictation instead of clobbering it.
                dictationSession = nil
                dictation.stop(reason: .textEdited)
            }
        }
        dictation.onDidStop = { reason in
            if !reason.acceptsFinalResult {
                dictationSession = nil
            }
        }
        Task { await dictation.startRecording() }
    }

    private func dictationHintRow(_ hint: String) -> some View {
        HStack(spacing: Constants.Conversation.Composer.dictationHintSpacing) {
            Image(systemName: "mic.slash")
                .font(.caption)
                .accessibilityHidden(true)
            Text(hint)
                .interFont(Constants.Typography.subtextXXS)
        }
        .foregroundStyle(Theme.mutedForeground(for: colorScheme))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Constants.Conversation.Composer.dictationHintHorizontalPadding)
        .padding(.top, Constants.Conversation.Composer.dictationHintTopPadding)
    }

    /// Suggested prompts as large chips directly above the field, sized for
    /// gaze targeting (≥60 pt). The transcript's inline prompt list is
    /// disabled on visionOS in favor of these.
    @ViewBuilder
    private var suggestedPromptChipsRow: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Constants.Conversation.Composer.suggestedPromptChipSpacing) {
                ForEach(viewModel.suggestedPrompts, id: \.self) { prompt in
                    Button {
                        Task { await viewModel.sendSuggestedPrompt(prompt) }
                    } label: {
                        HStack(spacing: Constants.Conversation.Composer.suggestedPromptContentSpacing) {
                            Image(systemName: "paperplane")
                                .font(.callout)
                                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                                .accessibilityHidden(true)
                            Text(LocalizedStringKey(prompt))
                                .interFont(Constants.Typography.bodyS)
                                .lineLimit(Constants.Conversation.Composer.suggestedPromptLineLimit)
                                .foregroundStyle(Theme.foreground(for: colorScheme))
                                .allowsHitTesting(false)
                        }
                        .padding(.horizontal, Constants.Conversation.Composer.suggestedPromptHorizontalPadding)
                        .frame(minHeight: Constants.Conversation.Composer.suggestedPromptChipMinimumHeight)
                        .background(Theme.muted(for: colorScheme).opacity(Constants.Conversation.Composer.suggestedPromptBackgroundOpacity))
                        .clipShape(Capsule())
                        .contentShape(.hoverEffect, Capsule())
                        .hoverEffect(.highlight)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Constants.Conversation.Composer.suggestedPromptsHorizontalPadding)
            .padding(.top, Constants.Conversation.Composer.suggestedPromptsTopPadding)
        }
        .scrollIndicators(.hidden)
    }
    #endif
}

private extension MessageInputView {
    // MARK: - Actions

    private func sendCurrentMessage() {
        guard isConnectionReadyForSending else { return }
        #if os(visionOS)
        // Stop app dictation before the text is consumed; a late final
        // result must not resurrect the sent text (.send cancels outright).
        dictation.stop(reason: .send)
        #endif

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
            guard !viewModel.isUploadingFiles, isConnectionReadyForSending else { return }
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
