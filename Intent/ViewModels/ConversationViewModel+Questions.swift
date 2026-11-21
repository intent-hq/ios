import Foundation

extension ConversationViewModel {
    // MARK: - Agent Q&A pending questions

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

    func discardQuestionAttachments(for messageId: String) {
        guard let pipeline = questionAttachmentPipelines.removeValue(forKey: messageId) else { return }
        pipeline.cancelPhotoImport()
        pipeline.pendingImages.removeAll()
        pipeline.clearPendingFiles()
    }

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

    private var nonResidentMarkedMessageId: String? {
        guard case .set(let markedId) = PendingQuestionSet.MarkerState(store.pendingQuestionsMessageId),
              !messages.contains(where: { $0.id == markedId }) else { return nil }
        return markedId
    }

    private var recoveredMarkedMessage: ConversationMessage? {
        guard let markedId = nonResidentMarkedMessageId,
              let recovery = store.pendingQuestionRecovery,
              recovery.messageId == markedId, recovery.status == .found else { return nil }
        return recovery.message
    }

    var isPendingQuestionRecoveryLoading: Bool {
        guard !isLoading, let markedId = nonResidentMarkedMessageId else { return false }
        guard let recovered = recoveredMarkedMessage else { return true }
        return PendingQuestionSet.derive(
            messages: [recovered],
            isTurnActive: false,
            pendingQuestionsMessageId: markedId
        ) == nil
    }

    func submitQuestionAnswers(
        _ answers: [QuestionAnswer],
        answeredQuestionsMessageId: String
    ) async {
        guard submittingQuestionMessageIds.insert(answeredQuestionsMessageId).inserted else { return }
        defer { submittingQuestionMessageIds.remove(answeredQuestionsMessageId) }
        let sendingStore = store
        let pendingMarker = sendingStore.pendingQuestionsMessageId
        let attachments = questionAttachmentPipelines[answeredQuestionsMessageId]
            ?? ConversationAttachmentPipeline(uploadService: uploadService)
        guard let payload = await buildQuestionAttachmentPayloads(attachments), store === sendingStore else { return }
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
            imagePlacementError = DiagnosticErrorOwnership.alertMessage(for: error)
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
        case .absent:
            return PendingQuestionSet.derive(
                messages: messages,
                isTurnActive: false
            )?.messageId == messageId
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
            imagePlacementError = DiagnosticErrorOwnership.alertMessage(for: error)
            return nil
        }
        do {
            let filePayload = try await attachments.buildFileBlocks(from: files, workspaceId: workspaceId)
            return (imagePayload, filePayload)
        } catch {
            attachments.filePlacementError = error.localizedDescription
            filePlacementError = DiagnosticErrorOwnership.alertMessage(for: error)
            return nil
        }
    }

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
            dismissQuestionsError = DiagnosticErrorOwnership.alertMessage(for: error)
        }
    }

    // MARK: - Suggested prompts parsing

    var suggestedPrompts: [String] {
        guard pendingQuestions == nil, !isPendingQuestionRecoveryLoading else { return [] }
        guard let lastMessage = messages.last,
              lastMessage.role == .assistant else { return [] }
        return SuggestedPrompts.parse(contentBlocks: lastMessage.contentBlocks).prompts
    }}
