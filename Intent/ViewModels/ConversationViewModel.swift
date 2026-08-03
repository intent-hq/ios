import Combine
import PhotosUI
import SwiftUI

@MainActor
class ConversationViewModel: ObservableObject {
    @Published var store = ConversationStore()
    /// Live background hooks for this conversation's workspace (PROTOCOL §5.40).
    @Published var hookStore = BackgroundHookStore()

    let agentId: String
    let workspaceId: String
    @Published var agentName: String

    var messages: [ConversationMessage] { store.messages }

    /// Messages filtered to exclude automated/system-injected user messages.
    var filteredMessages: [ConversationMessage] {
        store.messages.filter { message in
            // Keep all non-user messages
            guard message.role == .user else { return true }

            // Get the text content
            let text = (message.contentBlocks ?? [])
                .filter { $0.type == .text }
                .compactMap { $0.resolvedText }
                .joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)

            // Hide automated messages
            if text.hasPrefix("[WORKSPACE EVENTS]") { return false }
            if text.hasPrefix("[TASK WAKE]") { return false }
            if text.hasPrefix("[AGENT MESSAGE]") { return false }

            // Hide event notifications via metadata
            if let meta = message.metadata,
               let type = meta["type"]?.value as? String,
               type == "event_notification" {
                return false
            }

            return true
        }
    }
    var isStreaming: Bool { store.isStreaming }
    var isLoading: Bool { store.isLoading }
    var queuedMessages: [QueuedMessage] { store.queuedMessages }
    var isTruncated: Bool { store.isTruncated }
    var totalMessageCount: Int { store.totalMessageCount }
    var attentionRequest: PendingAttentionRequest? { store.attentionRequest }
    /// True when the daemon definitively reported the agent as gone (not-found
    /// at load or `agent:deleted` while open); the view falls back to the agent list.
    var agentNotFound: Bool { store.agentNotFound }
    /// This agent's active (`scheduled`/`running`) background hooks, for the
    /// chip row above the composer.
    var activeAgentHooks: [BackgroundHook] {
        hookStore.activeHooks.filter { $0.agentId == agentId }
    }

    // Message input
    @Published var messageText = ""

    // Model selection
    @Published var availableModels: [ModelInfo] = []
    @Published var currentModelId: String?

    // Specialist info (for empty state display)
    @Published var specialistName: String?
    @Published var specialistDescription: String?

    // Image attachments
    @Published var pendingImages: [UIImage] = []
    @Published var selectedPhotoItems: [PhotosPickerItem] = []

    private var cancellable: AnyCancellable?
    private var hookStoreCancellable: AnyCancellable?
    private var draftSaveCancellable: AnyCancellable?

    init(agentId: String, workspaceId: String, agentName: String) {
        self.agentId = agentId
        self.workspaceId = workspaceId
        self.agentName = agentName

        // Restore saved draft
        self.messageText = PersistenceManager.shared.loadDraft(
            workspaceId: workspaceId, agentId: agentId)

        // Forward store changes
        cancellable = store.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
        hookStoreCancellable = hookStore.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }

        // Debounced draft saving (0.5s)
        draftSaveCancellable = $messageText
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self] text in
                guard let self = self else { return }
                PersistenceManager.shared.saveDraft(
                    text, workspaceId: self.workspaceId, agentId: self.agentId)
            }
    }

    deinit {
        draftSaveCancellable?.cancel()
    }

    func load() async {
        // Subscribe to streaming BEFORE fetching the conversation snapshot.
        // This prevents a race condition where stream deltas arriving between
        // the fetch and the subscription would be lost.
        await store.subscribeToStreaming(agentId: agentId, workspaceId: workspaceId)
        // Subscribe to live chat updates (chat.subscribe)
        await store.subscribeLiveChat(agentId: agentId)

        // Run all independent fetches concurrently. fetchConversation,
        // fetchQueue, fetchCurrentModel, and fetchSubscriptions have no
        // dependencies on each other (only on subscribeToStreaming above).
        async let conversation: () = store.fetchConversation(agentId: agentId, workspaceId: workspaceId)
        async let queue: () = store.fetchQueue(agentId: agentId)
        async let model: () = fetchCurrentModel()
        async let subscriptions: () = store.fetchSubscriptions(agentId: agentId, workspaceId: workspaceId)
        // Backstop for mid-turn entry: restore the thinking indicator from the
        // agent's live state (raise-only, so it never clears snapshot/optimistic state).
        async let streamingState: () = store.fetchAgentStreamingState(agentId: agentId, raiseOnly: true)
        // Live background hooks (hook:* subscribe + hook.list seed, §5.40)
        async let hooks: () = hookStore.subscribe(workspaceId: workspaceId, agentId: agentId)

        _ = await (conversation, queue, model, subscriptions, streamingState, hooks)
    }

    /// Tears down the hook subscription when the conversation leaves the
    /// screen (`load()` re-subscribes on the next appearance).
    func teardownHooks() async {
        await hookStore.unsubscribe()
    }

    func cancelWait() async {
        await store.cancelSubscriptions(agentId: agentId, workspaceId: workspaceId)
    }

    func stopAgent(agentId: String) async {
        do {
            let _ = try await ConnectionManager.shared.request(
                "agent.stop", params: ["agentId": agentId])
        } catch {
            print("[ConversationViewModel] Failed to stop agent: \(error)")
        }
    }

    func stopAllWatchedAgents() async {
        let ids = store.watchedAgentIds
        await store.stopWatchedAgents(
            agentIds: ids, parentAgentId: agentId, workspaceId: workspaceId)
    }

    /// Fetch the agent's current model and specialist from the backend.
    private func fetchCurrentModel() async {
        do {
            let result = try await ConnectionManager.shared.request(
                "agent.get",
                params: ["agentId": agentId]
            )
            if let dict = result as? [String: Any],
               let agent = dict["agent"] as? [String: Any] {
                if let model = agent["model"] as? String {
                    currentModelId = model
                }
                // Extract specialist ID from metadata
                if let metadata = agent["metadata"] as? [String: Any],
                   let specialistId = metadata["specialist"] as? String {
                    await fetchSpecialistInfo(specialistId: specialistId)
                }
            }
        } catch {
            print("[ConversationViewModel] Fetch current model failed: \(error)")
        }
    }

    /// Fetch specialist name and description via specialist.list
    private func fetchSpecialistInfo(specialistId: String) async {
        do {
            let result = try await ConnectionManager.shared.request("specialist.list")
            if let dict = result as? [String: Any],
               let items = dict["specialists"] as? [[String: Any]] {
                if let match = items.first(where: { ($0["id"] as? String) == specialistId }) {
                    specialistName = match["name"] as? String
                    specialistDescription = match["description"] as? String
                }
            }
        } catch {
            print("[ConversationViewModel] Fetch specialist info failed: \(error)")
        }
    }

    // MARK: - Send / Queue

    func sendMessage(_ content: String, images: [UIImage]? = nil) async {
        let imageBlocks = buildImageBlocks(from: images ?? pendingImages)
        do {
            try await store.sendMessage(agentId: agentId, content: content, workspaceId: workspaceId, imageBlocks: imageBlocks)
            // Clear draft immediately after successful send
            PersistenceManager.shared.clearDraft(workspaceId: workspaceId, agentId: agentId)
        } catch {
            print("[ConversationViewModel] Send failed: \(error)")
        }
    }

    func queueMessage(_ content: String) async {
        let imageBlocks = buildImageBlocks()
        do {
            try await store.queueMessage(agentId: agentId, content: content, imageBlocks: imageBlocks)
            pendingImages.removeAll()
        } catch {
            print("[ConversationViewModel] Queue failed: \(error)")
        }
    }

    func stopStreaming() async {
        await store.stopStreaming(agentId: agentId)
    }

    // MARK: - Queue management

    func editQueuedMessage(messageId: String, content: String) async {
        do {
            try await store.editQueuedMessage(agentId: agentId, messageId: messageId, content: content)
        } catch {
            print("[ConversationViewModel] Edit queued message failed: \(error)")
        }
    }

    func removeQueuedMessage(messageId: String) async {
        do {
            try await store.removeQueuedMessage(agentId: agentId, messageId: messageId)
        } catch {
            print("[ConversationViewModel] Remove queued message failed: \(error)")
        }
    }

    func sendQueuedMessageNow(messageId: String) async {
        do {
            try await store.sendQueuedMessageNow(agentId: agentId, messageId: messageId, workspaceId: workspaceId)
        } catch {
            print("[ConversationViewModel] Send now failed: \(error)")
        }
    }

    // MARK: - Models

    func fetchModels() async {
        do {
            // Backend returns flat: [{ id: "sonnet4.5", name: "sonnet4.5 (balanced)", provider: "auggie" }]
            let raw = try await store.getModels(agentId: agentId)
            availableModels = raw.compactMap { dict -> ModelInfo? in
                guard let id = dict["id"] as? String,
                      let name = dict["name"] as? String else { return nil }
                let provider = dict["provider"] as? String ?? "Unknown"
                return ModelInfo(id: id, name: name, provider: provider)
            }
        } catch {
            print("[ConversationViewModel] Fetch models failed: \(error)")
        }
    }

    func setModel(_ modelId: String) async {
        do {
            try await store.setModel(agentId: agentId, modelId: modelId, workspaceId: workspaceId)
            currentModelId = modelId
        } catch {
            print("[ConversationViewModel] Set model failed: \(error)")
        }
    }

    func renameAgent(_ newName: String) async throws {
        let _ = try await ConnectionManager.shared.request(
            "agent.rename",
            params: [
                "agentId": agentId,
                "name": newName,
                "workspaceId": workspaceId
            ]
        )
        agentName = newName
    }

    // MARK: - Image attachments

    func addImage(_ image: UIImage) {
        pendingImages.append(image)
    }

    func removeImage(at index: Int) {
        guard pendingImages.indices.contains(index) else { return }
        pendingImages.remove(at: index)
    }

    func loadSelectedPhotos() async {
        for item in selectedPhotoItems {
            if let data = try? await item.loadTransferable(type: Data.self),
               let image = UIImage(data: data) {
                pendingImages.append(image)
            }
        }
        selectedPhotoItems.removeAll()
    }

    private func buildImageBlocks(from images: [UIImage]? = nil) -> [[String: Any]]? {
        let source = images ?? pendingImages
        guard !source.isEmpty else { return nil }
        return source.compactMap { image -> [String: Any]? in
            guard let data = image.jpegData(compressionQuality: 0.8) else { return nil }
            // Skip images over 10MB
            guard data.count <= 10 * 1024 * 1024 else { return nil }
            return [
                "type": "image",
                "data": data.base64EncodedString(),
                "mimeType": "image/jpeg",
            ]
        }
    }

    // MARK: - Agent Q&A pending questions

    /// Pending Agent Q&A question set for the composer-slot wizard, derived
    /// purely from the transcript (nil while streaming/turn-active or once a
    /// later user message supersedes the questions). The optimistic user
    /// message appended by `sendMessage` supersedes derivationally — and the
    /// store raises `isStreaming` optimistically — so the wizard also hides
    /// while a send is in flight. A failed wizard send is rolled back
    /// (`ConversationStore.rollbackFailedSend`) so unanswered questions
    /// re-pend instead of being permanently superseded.
    var pendingQuestions: PendingQuestionSet? {
        PendingQuestionSet.derive(messages: messages, isTurnActive: isStreaming)
    }

    /// Flatten the wizard's answers into ONE plain-text user message of
    /// `Q:`/`A:` pairs and send it through the ordinary send path (wire
    /// contract — no metadata, no image attachments). Completing the wizard
    /// clears any pending composer image attachments (FE parity:
    /// `ChatPanel.performLocalSendCleanup`) so stale images never ride a
    /// later message.
    func submitQuestionAnswers(_ answers: [QuestionAnswer]) async {
        pendingImages.removeAll()
        do {
            try await store.sendMessage(
                agentId: agentId,
                content: QuestionAnswer.flattenToMessage(answers),
                workspaceId: workspaceId)
        } catch {
            print("[ConversationViewModel] Submit question answers failed: \(error)")
            store.rollbackFailedSend()
        }
    }

    // MARK: - Suggested prompts parsing

    var suggestedPrompts: [String] {
        // Suggested prompts stay hidden whenever the turn has pending Agent
        // Q&A questions — including while the wizard is Ignore-collapsed.
        // Only answering (or any superseding user message) brings them back.
        guard pendingQuestions == nil else { return [] }
        guard let lastMessage = messages.last,
              lastMessage.role == .assistant else { return [] }
        let blocks = lastMessage.contentBlocks ?? []
        for block in blocks.reversed() {
            guard block.type == .text, let text = block.resolvedText else { continue }
            if let range = text.range(of: "<!-- suggested-prompts"),
               let endRange = text.range(of: "-->", range: range.upperBound..<text.endIndex) {
                let inner = text[range.upperBound..<endRange.lowerBound]
                return inner
                    .split(separator: "\n")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            }
        }
        return []
    }
}

