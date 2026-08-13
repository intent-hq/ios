import Combine
import PhotosUI
import SwiftUI

@MainActor
class ConversationViewModel: ObservableObject {
    @Published var store = ConversationStore()
    /// Live background hooks for this conversation's workspace (PROTOCOL §5.40).
    @Published var hookStore = BackgroundHookStore()
    /// Live PR monitors for this conversation's workspace (PROTOCOL §5.42).
    @Published var monitoredPrStore = MonitoredPrStore()

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
    /// Display-only filter: hide daemon-originated queue entries (system
    /// wakes without a dedicated row) from the queued-messages section —
    /// except hook wakes, PR-monitor wakes (PROTOCOL §5.40 / §5.42),
    /// agent-to-agent sends (`agent_message`), and event-notification wakes,
    /// which render as compact attribution rows (FE parity:
    /// QueuedMessageList). The store keeps the full queue and flush behavior
    /// is unchanged.
    var queuedMessages: [QueuedMessage] {
        store.queuedMessages.filter {
            $0.isUserMessage
                || $0.hookWakeAttribution != nil
                || $0.prMonitorWakeAttribution != nil
                || $0.agentMessageAttribution != nil
                || $0.isEventNotificationWake
        }
    }
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
    /// This agent's active PR monitors, for the chip row above the composer
    /// (rendered above the hooks row, mirroring the FE).
    var activeAgentMonitors: [MonitoredPr] {
        monitoredPrStore.activeMonitors.filter { $0.agentId == agentId }
    }
    /// `<owner>/<repo>` of this conversation's workspace, or nil when unknown
    /// (chip labels then fall back to the bare `#<n>` form).
    var workspaceRepo: String? {
        guard let ws = WorkspaceStore.shared.workspaces.first(where: { $0.id == workspaceId }),
              let owner = ws.repositoryOwner, let name = ws.repositoryName else { return nil }
        return "\(owner)/\(name)"
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
    private var monitoredPrStoreCancellable: AnyCancellable?
    private var workspaceStoreCancellable: AnyCancellable?
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
        monitoredPrStoreCancellable = monitoredPrStore.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
        // `workspaceRepo` reads WorkspaceStore.shared on the fly — forward its
        // changes so chip labels pick up the repo once the workspace list loads.
        workspaceStoreCancellable = WorkspaceStore.shared.objectWillChange
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
        // Live PR monitors (prMonitor:* subscribe + prMonitor.list seed, §5.42)
        async let monitors: () = monitoredPrStore.subscribe(workspaceId: workspaceId, agentId: agentId)

        _ = await (conversation, queue, model, subscriptions, streamingState, hooks, monitors)
    }

    /// Tears down the live-store subscriptions (background hooks + PR
    /// monitors) when the conversation leaves the screen (`load()`
    /// re-subscribes on the next appearance).
    func teardownLiveStores() async {
        await hookStore.unsubscribe()
        await monitoredPrStore.unsubscribe()
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

    /// Send a suggested prompt as-is: prompt text only. Unlike `sendMessage`,
    /// this never attaches `pendingImages` and never clears the persisted
    /// composer draft — the in-progress draft (text + attachments) stays
    /// intact for the user's own message.
    func sendSuggestedPrompt(_ prompt: String) async {
        do {
            try await store.sendMessage(agentId: agentId, content: prompt, workspaceId: workspaceId)
        } catch {
            print("[ConversationViewModel] Send suggested prompt failed: \(error)")
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
    /// re-pend instead of being permanently superseded. A set the user
    /// dismissed (`agent.dismissQuestions` marker, PROTOCOL §5.5) never pends.
    var pendingQuestions: PendingQuestionSet? {
        PendingQuestionSet.derive(
            messages: messages, isTurnActive: isStreaming,
            dismissedQuestionsMessageId: store.dismissedQuestionsMessageId)
    }

    /// Flatten the wizard's answers into ONE plain-text user message of
    /// `Q:`/`A:` pairs and send it through the ordinary send path tagged with
    /// `messageMetadata { type: "question_answers",
    /// answeredQuestionsMessageId }` (wire contract — no image attachments).
    /// The structured tag, never the answer text, is what makes the daemon
    /// retire the question hold and demote `needs_attention` (FE parity:
    /// `answer-message.ts` / `ChatPanel`). `answeredQuestionsMessageId` is the
    /// wizard's mount-time question-bearing assistant message id (the wizard
    /// is `.id`-keyed on it) — passed in rather than re-derived here so a
    /// derivation flip between the tap and this main-actor hop (pushed stream
    /// start, superseding row from another client) can never send the answer
    /// untagged. Completing the wizard clears any pending composer image
    /// attachments (FE parity: `ChatPanel.performLocalSendCleanup`) so stale
    /// images never ride a later message.
    func submitQuestionAnswers(_ answers: [QuestionAnswer],
                               answeredQuestionsMessageId: String) async {
        pendingImages.removeAll()
        do {
            try await store.sendMessage(
                agentId: agentId,
                content: QuestionAnswer.flattenToMessage(answers),
                workspaceId: workspaceId,
                messageMetadata: [
                    "type": "question_answers",
                    "answeredQuestionsMessageId": answeredQuestionsMessageId,
                ])
        } catch {
            print("[ConversationViewModel] Submit question answers failed: \(error)")
            store.rollbackFailedSend()
        }
    }

    /// User-facing message for a failed `agent.dismissQuestions`
    /// (intent-hq/monorepo#1800) — the view presents it as a non-destructive
    /// alert. Nil when there is nothing to surface.
    @Published var dismissQuestionsError: String?

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
                agentId: agentId, messageId: messageId, workspaceId: workspaceId)
        } catch {
            print("[ConversationViewModel] Dismiss questions failed: \(error)")
            dismissQuestionsError = error.localizedDescription
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
        // Text blocks are joined with newlines so a block boundary never fuses
        // two lines, then only the last well-formed block supplies prompts
        // (see `SuggestedPrompts`).
        let text = (lastMessage.contentBlocks ?? [])
            .filter { $0.type == .text }
            .compactMap { $0.resolvedText }
            .joined(separator: "\n")
        return SuggestedPrompts.parse(text)
    }
}

