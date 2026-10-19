import Foundation

extension ConversationViewModel {
    // MARK: - Agent Q&A pending questions

    /// A question set owns its selection independently of the ordinary composer
    /// and other question sets. Reuse it across wizard remounts and failed sends.
    func questionAttachments(for messageId: String) -> ConversationAttachmentPipeline {
        if let pipeline = questionAttachmentPipelines[messageId] { return pipeline }
        for supersededId in Array(questionAttachmentPipelines.keys) {
            discardQuestionAttachments(for: supersededId)
        }
        let pipeline = ConversationAttachmentPipeline(
            uploadService: uploadService,
            maximumPhotoImageCount: Constants.Conversation.Composer.maximumImageSelectionCount
        )
        questionAttachmentPipelines[messageId] = pipeline
        return pipeline
    }

    /// Release the selection and imports when this question set is retired.
    func discardQuestionAttachments(for messageId: String) {
        guard let pipeline = questionAttachmentPipelines.removeValue(forKey: messageId) else { return }
        pipeline.cancelPhotoImport()
        pipeline.pendingImages.removeAll()
        pipeline.clearPendingFiles()
    }

    /// Pending Agent Q&A question set for the composer-slot wizard. When the
    /// daemon's `pendingQuestionsMessageId` marker is present (PROTOCOL §5.5)
    /// it is authoritative: the marked set appears once the asking turn ends
    /// and stays STICKY across later turns — automatic deliveries or a plain
    /// user message do not hide it. It hides only once a user row carries the
    /// `question_answers` tag naming it (the optimistic answer row appended by
    /// `submitQuestionAnswers` mirrors the tag, so Send hides it immediately;
    /// when the daemon auto-queues that answer mid-turn the tag lives on the
    /// queue entry instead, which counts the same), once it is dismissed
    /// (`agent.dismissQuestions` marker), or once the
    /// daemon clears the marker to `""`. Against a legacy daemon (marker
    /// absent) the transcript-tail fallback applies: nil while the turn is
    /// active (`isStreaming`) or once a later user message supersedes it. A
    /// failed wizard send is rolled back (`ConversationStore.rollbackFailedSend`)
    /// so unanswered questions re-pend in both paths.
    ///
    /// When the marked row is outside the loaded page, the copy recovered by
    /// the store's targeted seek (`pendingQuestionRecovery`, status `found`)
    /// is prepended to the transcript for the derivation, so the marker path
    /// finds it while the tail is still scanned for the tagged answer row and
    /// the queued-answer / dismissal bridges apply unchanged. A resident row
    /// always wins over the recovered copy (FE parity: `wizard-gate.ts`
    /// `deriveWizardPendingQuestions`).
    var pendingQuestions: PendingQuestionSet? {
        var derivationMessages = messages
        if let recovered = recoveredMarkedMessage {
            derivationMessages.insert(recovered, at: 0)
        }
        return PendingQuestionSet.derive(
            messages: derivationMessages,
            isTurnActive: isStreaming,
            dismissedQuestionsMessageId: store.dismissedQuestionsMessageId,
            pendingQuestionsMessageId: store.pendingQuestionsMessageId,
            queuedAnsweredQuestionsMessageIds: Set(
                store.queuedMessages.compactMap(\.answeredQuestionsMessageId)
            )
        )
    }

    /// The marker's id when it names a row that is NOT in the loaded
    /// transcript, else nil. Both recovery-aware derivations key off this.
    private var nonResidentMarkedMessageId: String? {
        guard case .set(let markedId) = PendingQuestionSet.MarkerState(store.pendingQuestionsMessageId),
              !messages.contains(where: { $0.id == markedId }) else { return nil }
        return markedId
    }

    /// The recovered copy of the marked row (store seek settled `found` for
    /// the CURRENT marker id) while that row is not resident, else nil. A
    /// stale recovery for another id, or one superseded by the row arriving
    /// in the transcript, is ignored.
    private var recoveredMarkedMessage: ConversationMessage? {
        guard let markedId = nonResidentMarkedMessageId,
              let recovery = store.pendingQuestionRecovery,
              recovery.messageId == markedId, recovery.status == .found else { return nil }
        return recovery.message
    }

    /// Fail-closed gate for the composer slot: true while the marker names a
    /// row that is not resident and no recovered wizard can be rendered from
    /// it — the seek is in flight, settled `notFound`/`error`, or found a row
    /// without a valid question set. Exhausted retries end the network
    /// attempts, not marker authority: the ordinary composer and suggested
    /// prompts stay withheld until the daemon clears or replaces the marker
    /// (FE parity: `deriveMarkedQuestionRecoveryState` + ChatPanel's
    /// `pendingQuestionRecoveryLoading`). False until the initial transcript
    /// fetch has settled — the row may simply not have loaded yet — and false
    /// once a recovered wizard exists, even if it is answered or dismissed.
    var isPendingQuestionRecoveryLoading: Bool {
        guard !isLoading, let markedId = nonResidentMarkedMessageId else { return false }
        guard let recovered = recoveredMarkedMessage else { return true }
        return PendingQuestionSet.derive(
            messages: [recovered],
            isTurnActive: false,
            pendingQuestionsMessageId: markedId
        ) == nil
    }

    /// Flatten the wizard's answers into ONE user message of
    /// `Q:`/`A:` pairs and send it through the ordinary send path tagged with
    /// `messageMetadata { type: "question_answers",
    /// answeredQuestionsMessageId }`, together with the question set's attachments.
    /// The structured tag, never the answer text, is what makes the daemon
    /// retire the question hold and demote `needs_attention` (FE parity:
    /// `answer-message.ts` / `ChatPanel`). `answeredQuestionsMessageId` is the
    /// wizard's mount-time question-bearing assistant message id (the wizard
    /// is `.id`-keyed on it) — passed in rather than re-derived here so a
    /// derivation flip between the tap and this main-actor hop (pushed stream
    /// start, superseding row from another client) can never send the answer
    /// untagged. Upload failures preserve the selection for retry; successful
    /// sends retire only this question set's attachments, never the composer's.
    func submitQuestionAnswers(
        _ answers: [QuestionAnswer],
        answeredQuestionsMessageId: String
    ) async {
        guard submittingQuestionMessageIds.insert(answeredQuestionsMessageId).inserted else { return }
        defer { submittingQuestionMessageIds.remove(answeredQuestionsMessageId) }
        let sendingStore = store
        let pendingMarker = sendingStore.pendingQuestionsMessageId
        // A late submit for an older mount must not replace a newer card's selection.
        let attachments = questionAttachmentPipelines[answeredQuestionsMessageId]
            ?? ConversationAttachmentPipeline(uploadService: uploadService)
        guard let payload = await buildQuestionAttachmentPayloads(attachments), store === sendingStore else { return }
        // Uploads suspend before the optimistic answer exists. Remote retirement
        // must win here even though the view lifecycle exempts submitting IDs.
        guard questionSubmissionIsCurrent(answeredQuestionsMessageId, pendingMarker: pendingMarker) else {
            discardQuestionAttachments(for: answeredQuestionsMessageId)
            return
        }
        do {
            try await sendingStore.sendMessage(
                agentId: agentId,
                content: QuestionAnswer.flattenToMessage(answers),
                workspaceId: workspaceId,
                imagePayload: payload.images,
                filePayload: payload.files,
                messageMetadata: .fields([
                    "type": "question_answers",
                    "answeredQuestionsMessageId": answeredQuestionsMessageId
                ])
            )
            discardQuestionAttachments(for: answeredQuestionsMessageId)
        } catch let error as OutgoingImagePayload.RequestError {
            attachments.imagePlacementError = error.localizedDescription
            imagePlacementError = error.localizedDescription
            sendingStore.rollbackFailedSend()
        } catch {
            AppLog.conversation.error("[ConversationViewModel] Submit question answers failed: \(error)")
            sendingStore.rollbackFailedSend()
        }
    }

    private func questionSubmissionIsCurrent(_ messageId: String, pendingMarker: String?) -> Bool {
        guard store.pendingQuestionsMessageId == pendingMarker,
              store.dismissedQuestionsMessageId != messageId,
              !PendingQuestionSet.isQuestionSetAnswered(messages: messages, messageId: messageId),
              !store.queuedMessages.contains(where: { $0.answeredQuestionsMessageId == messageId }) else { return false }
        switch PendingQuestionSet.MarkerState(pendingMarker) {
        case .cleared: return false
        case .set(let markedId): return markedId == messageId
        // Legacy visibility can flip during a new turn. Preserve the mount-time
        // answer tag unless an authoritative retirement signal arrives.
        case .absent: return true
        }
    }

    private func buildQuestionAttachmentPayloads(_ attachments: ConversationAttachmentPipeline) async
        -> (images: OutgoingImagePayload, files: OutgoingFilePayload)? {
        let images = attachments.pendingImages
        let files = attachments.pendingFiles
        let fileAccess = attachments.retainFileAccess(for: files)
        defer { withExtendedLifetime(fileAccess) {} }
        attachments.imagePlacementError = nil
        attachments.filePlacementError = nil
        let imagePayload: OutgoingImagePayload
        do {
            imagePayload = try await attachments.buildImageBlocks(from: images, workspaceId: workspaceId)
        } catch {
            attachments.imagePlacementError = error.localizedDescription
            imagePlacementError = error.localizedDescription
            return nil
        }
        do {
            let filePayload = try await attachments.buildFileBlocks(from: files, workspaceId: workspaceId)
            return (imagePayload, filePayload)
        } catch {
            attachments.filePlacementError = error.localizedDescription
            filePlacementError = error.localizedDescription
            return nil
        }
    }

    /// Dismiss the pending question set WITHOUT answering
    /// (`agent.dismissQuestions`). Persistent — unlike Ignore's transient
    /// collapse, the daemon-persisted marker means the set never re-pends,
    /// even after reload. `messageId` is the wizard's mount-time
    /// question-bearing assistant message id (same capture discipline as
    /// `submitQuestionAnswers`). A failed RPC leaves the wizard pending
    /// (the store rolls the optimistic marker back) and surfaces
    /// `dismissQuestionsError`.
    func dismissQuestions(messageId: String) async {
        dismissQuestionsError = nil
        do {
            try await store.dismissQuestions(
                agentId: agentId,
                messageId: messageId,
                workspaceId: workspaceId
            )
            discardQuestionAttachments(for: messageId)
        } catch {
            AppLog.conversation.error("[ConversationViewModel] Dismiss questions failed: \(error)")
            dismissQuestionsError = error.localizedDescription
        }
    }

    // MARK: - Suggested prompts parsing

    var suggestedPrompts: [String] {
        // Suggested prompts stay hidden whenever the turn has pending Agent
        // Q&A questions — including while the wizard is Ignore-collapsed —
        // and while the marked question row is still being recovered
        // (fail-closed, like the composer). Only answering (or any
        // superseding user message) brings them back.
        guard pendingQuestions == nil, !isPendingQuestionRecoveryLoading else { return [] }
        guard let lastMessage = messages.last,
              lastMessage.role == .assistant else { return [] }
        // The same message-level scan the views use for stripping (empty
        // join like the desktop, so mid-line splits reassemble): prompts and
        // stripping come from one scan and can never disagree
        // (intent-hq/intent#3936; see `SuggestedPrompts.parse(contentBlocks:)`).
        return SuggestedPrompts.parse(contentBlocks: lastMessage.contentBlocks).prompts
    }}
