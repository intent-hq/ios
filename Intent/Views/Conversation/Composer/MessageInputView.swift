import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct MessageInputView: View {
    // Bind directly to the model so received edits and external replacements
    // share one draft. Deferred bidirectional onChange copies can replay old text.
    @Bindable var viewModel: ConversationViewModel
    private let store: ConversationStore
    private let usesWorkspaceDesign: Bool
    private let allowsSending: Bool
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.conversationPresentation) private var presentation
    @Environment(\.isIPadPaneVisible) private var isIPadPaneVisible
    @Environment(\.workspaceQuestionPanelPresented) private var questionPanelPresented
    @Environment(\.conversationComposerFocus) private var conversationFocus
    @ScaledMetric(relativeTo: .title2) private var controlIconSide: CGFloat = 22
    @ScaledMetric(relativeTo: .caption) var attachmentIconSide: CGFloat = 12
    @ScaledMetric(relativeTo: .callout) private var suggestedPromptIconSide: CGFloat = 16
    private let sendArrowScale: CGFloat = 0.75

    @State private var localFocus = false
    @State private var textViewHeight: CGFloat = Constants.Conversation.Composer.minimumTextViewHeight
    @State private var isPhotoPickerPresented: Bool = false
    @State private var isFilePickerPresented: Bool = false
    @State private var skillCompletion = ComposerSkillCompletion()

    #if os(visionOS)
    @Environment(\.scenePhase) private var scenePhase
    @State private var dictation = SpeechDictationController()
    @State private var dictationSession: DictationSession?
    /// Last observed caret offset; dictation treats nil as end-of-text.
    @State private var caretOffset: Int?
    #endif

    init(
        viewModel: ConversationViewModel,
        store: ConversationStore,
        usesWorkspaceDesign: Bool = false,
        allowsSending: Bool = true
    ) {
        self.viewModel = viewModel
        self.store = store
        self.usesWorkspaceDesign = usesWorkspaceDesign
        self.allowsSending = allowsSending
    }

    private var focusBinding: Binding<Bool> { conversationFocus ?? $localFocus }

    private var isFocused: Bool {
        get { focusBinding.wrappedValue }
        nonmutating set { focusBinding.wrappedValue = newValue }
    }

    /// Read live connection state at both submission boundaries before consuming a draft.
    var isConnectionReadyForSending: Bool { viewModel.connection.connectionState == .connected }

    var body: some View {
        IPadTypingFocusRow(isFocused: focusBinding) { VStack(spacing: 0) { ComposerFloatingRow { skillChips }; inputContent } }
        .photosPicker(
            isPresented: $isPhotoPickerPresented,
            selection: $viewModel.selectedPhotoItems,
            maxSelectionCount: Constants.Conversation.Composer.maximumImageSelectionCount,
            matching: viewModel.workspaceId == Workspace.chiefWorkspaceId ? .images : .any(of: [.images, .videos])
        )
        .onChange(of: viewModel.selectedPhotoItems) { _, _ in
            viewModel.loadSelectedPhotos()
        }
        #if !os(visionOS)
        .onDisappear { viewModel.cancelPhotoImport() } // visionOS: FloatingComposerOrnament's onWithdraw
        #endif
        .fileImporter(
            isPresented: $isFilePickerPresented,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                viewModel.addFiles(urls)
            }
        }
        .onChange(of: isEnabled) { _, enabled in
            if !enabled { isFocused = false }
        }
        .onChange(of: isIPadPaneVisible) { _, visible in
            if presentation == .iPad, !visible { isFocused = false }
        }
        .onChange(of: questionPanelPresented) { _, presented in
            // Resign explicitly rather than disabling the native editor: UIKit
            // restores a disabled first responder when the panel closes.
            if presented { isFocused = false }
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
    var inputContent: some View {
        VStack(spacing: 0) {
            supplementalRows
            if usesWorkspaceDesign {
                WorkspaceComposerRow(
                    text: $viewModel.messageText,
                    isFocused: focusBinding,
                    isStreaming: store.isStreaming,
                    hasAttachments: viewModel.hasPendingAttachments,
                    canSend: hasSendableContent,
                    onSend: sendCurrentMessage,
                    onStop: {
                        HapticManager.impact(.light)
                        Task { await viewModel.stopStreaming() }
                    },
                    onPhotos: { isPhotoPickerPresented = true },
                    onFiles: { isFilePickerPresented = true },
                    onPasteImages: viewModel.pasteImages,
                    skillCompletion: skillCompletion
                )
            } else {
                inputRow
            }
        }
        .background {
            if usesWorkspaceDesign {
                WorkspaceComposerSurface(text: viewModel.messageText, hasAttachments: viewModel.hasPendingAttachments, isStreaming: store.isStreaming)
            } else {
                #if os(visionOS)
                Color.clear // the floating ornament host supplies the glass
                #else
                Theme.card(for: colorScheme).opacity(viewModel.showsLoadingState ? 0 : 1)
                #endif
            }
        }
    }

    @ViewBuilder var skillChips: some View {
        if isFocused, skillCompletion.context != nil { SkillSuggestionsView(completion: skillCompletion, workspaceId: viewModel.workspaceId, agentId: viewModel.agentId, connection: viewModel.connection) }
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
        if viewModel.isLoadingPhotos {
            ProgressView("Loading attachments…")
                .padding(.top, Constants.Conversation.Composer.pendingImagesTopPadding)
        }
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
        .buttonStyle(IntentContentButtonStyle())
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
        .buttonStyle(IntentContentButtonStyle())
        .accessibilityLabel("Add attachment")
    }

    var textEditor: some View {
        ZStack(alignment: .leading) {
            SubmittableTextView(
                text: $viewModel.messageText,
                isFocused: focusBinding,
                onSubmit: { sendCurrentMessage() },
                onPasteImages: viewModel.pasteImages,
                onHeightChange: updateTextViewHeight,
                onCaretChange: updateCaretOffset,
                skillCompletion: skillCompletion
            )
            .padding(.horizontal, Constants.Conversation.Composer.textEditorHorizontalPadding)
            .padding(.vertical, Constants.Conversation.Composer.fieldVerticalPadding)
            .frame(height: textViewHeight)
            if viewModel.messageText.isEmpty {
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
        (!viewModel.messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || viewModel.hasPendingAttachments)
            && !viewModel.isUploadingFiles
            && !viewModel.isLoadingPhotos
            && isConnectionReadyForSending
            && allowsSending
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
                .buttonStyle(IntentContentButtonStyle())
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
        .buttonStyle(IntentContentButtonStyle())
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

        dictationSession = DictationSession(baseText: viewModel.messageText, insertionOffset: caretOffset)
        dictation.onTranscriptChange = { transcription, endsSegment in
            guard var session = dictationSession else { return }
            switch session.apply(transcription: transcription, endsSegment: endsSegment, to: viewModel.messageText) {
            case .merged(let text):
                viewModel.messageText = text
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
                            Image(.arrowRight)
                                .resizable()
                                .scaledToFit()
                                .frame(width: suggestedPromptIconSide, height: suggestedPromptIconSide)
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
                    .buttonStyle(IntentContentButtonStyle())
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
        guard isConnectionReadyForSending, allowsSending else { return }
        #if os(visionOS)
        // Stop app dictation before the text is consumed; a late final
        // result must not resurrect the sent text (.send cancels outright).
        dictation.stop(reason: .send)
        #endif

        // Commit active dictation before reading the final text below.
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
            guard !viewModel.isUploadingFiles, !viewModel.isLoadingPhotos,
                  isConnectionReadyForSending, allowsSending else { return }
            let text = viewModel.messageText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty || viewModel.hasPendingAttachments else {
                isFocused = true
                return
            }
            HapticManager.impact(.medium)
            // Capture images before clearing so they're available for the async send
            let imagesToSend = viewModel.pendingImages
            viewModel.messageText = ""
            viewModel.pendingImages.removeAll()
            // Sending ends editing on every device; only an explicit tap reopens it.
            isFocused = false
            Task { await viewModel.sendMessage(text, images: imagesToSend) }
        }
    }
}
