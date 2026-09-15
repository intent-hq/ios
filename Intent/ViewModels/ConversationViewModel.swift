import Combine
import PhotosUI
import SwiftUI

@MainActor
@Observable class ConversationViewModel {
    var store: ConversationStore {
        didSet {
            oldValue.onStreamingChanged = nil
            observeStreaming()
        }
    }
    /// Live background hooks for this conversation's workspace (PROTOCOL §5.40).
    var hookStore: BackgroundHookStore
    /// Live PR monitors for this conversation's workspace (PROTOCOL §5.42).
    var monitoredPrStore: MonitoredPrStore

    /// The window's backend connection, injected from its `BackendSession`.
    @ObservationIgnored private let connection: any ConnectionManagerRouting

    let agentId: String
    let workspaceId: String
    var agentName: String

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

    /// Id of the message the "New messages" divider renders after, or nil
    /// when hidden. Applies the latched per-session anchor against the
    /// current transcript (PROTOCOL §5.5 seen marker; FE parity:
    /// new-messages-divider.ts): a latched `nil` hides the divider for the
    /// whole viewing session, and an anchor that left the transcript (e.g.
    /// `agent.editAndRegenerate` truncation) hides it WITHOUT re-deriving.
    var newMessagesDividerAnchorId: String? {
        NewMessagesDivider.resolveLatchedAnchor(
            messageIds: store.messages.map(\.id),
            latchedAnchorId: latchedNewMessagesDividerAnchorId
        )
    }

    /// Latched divider anchor for this viewing session (FE parity: Redux
    /// unreadTracking.dividerSessionByAgentId). Derived ONCE when the initial
    /// `load()` fetches settle and kept for the lifetime of the view model —
    /// later `agent:updated` marker convergence or new messages never move or
    /// add the divider.
    private var latchedNewMessagesDividerAnchorId: String?
    private var hasLatchedNewMessagesDividerAnchor = false

    // Message input
    var messageText = "" {
        didSet { draftTextSubject.send(messageText) }
    }

    // Model selection
    var availableModels: [ModelInfo] = []
    var currentModelId: String?

    // Specialist info (for empty state display)
    var specialistName: String?
    var specialistDescription: String?

    /// User-facing message for a failed `agent.dismissQuestions`
    /// (intent-hq/monorepo#1800) — the view presents it as a non-destructive
    /// alert. Nil when there is nothing to surface.
    var dismissQuestionsError: String?

    private let attachmentPipeline: ConversationAttachmentPipeline
    var pendingImages: [UIImage] {
        get { attachmentPipeline.pendingImages }
        set { attachmentPipeline.pendingImages = newValue }
    }
    var selectedPhotoItems: [PhotosPickerItem] {
        get { attachmentPipeline.selectedPhotoItems }
        set { attachmentPipeline.selectedPhotoItems = newValue }
    }
    var pendingFiles: [PendingFile] {
        get { attachmentPipeline.pendingFiles }
        set { attachmentPipeline.pendingFiles = newValue }
    }
    var fileUploadProgress: [UUID: Double] {
        get { attachmentPipeline.fileUploadProgress }
        set { attachmentPipeline.fileUploadProgress = newValue }
    }
    var imagePlacementError: String? {
        get { attachmentPipeline.imagePlacementError }
        set { attachmentPipeline.imagePlacementError = newValue }
    }
    var filePlacementError: String? {
        get { attachmentPipeline.filePlacementError }
        set { attachmentPipeline.filePlacementError = newValue }
    }

    @ObservationIgnored private let draftTextSubject = PassthroughSubject<String, Never>()
    @ObservationIgnored private var draftSaveCancellable: AnyCancellable?

    var uploadService: AttachmentUploadService {
        get { attachmentPipeline.uploadService }
        set { attachmentPipeline.uploadService = newValue }
    }

    init(
        agentId: String,
        workspaceId: String,
        agentName: String,
        connection: any ConnectionManagerRouting,
        uploadService: AttachmentUploadService
    ) {
        self.agentId = agentId
        self.workspaceId = workspaceId
        self.agentName = agentName
        self.connection = connection
        self.store = ConversationStore(connectionManager: connection)
        self.hookStore = BackgroundHookStore(connectionManager: connection)
        self.monitoredPrStore = MonitoredPrStore(connectionManager: connection)
        self.attachmentPipeline = ConversationAttachmentPipeline(uploadService: uploadService)

        // Restore saved draft
        self.messageText = PersistenceManager.shared.loadDraft(
            workspaceId: workspaceId,
            agentId: agentId
        )

        // Debounced draft saving (0.5s)
        draftSaveCancellable = draftTextSubject
            .debounce(
                for: .milliseconds(Constants.Conversation.Composer.draftSaveDebounceMilliseconds),
                scheduler: DispatchQueue.main
            )
            .sink { [weak self] text in
                guard let self else { return }
                PersistenceManager.shared.saveDraft(
                    text,
                    workspaceId: self.workspaceId,
                    agentId: self.agentId
                )
            }

        observeStreaming()
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

        // Derive + latch the "New messages" divider anchor exactly once, as
        // soon as both inputs — the transcript (fetchConversation) and the
        // seen marker (fetchAgentStreamingState → agent.get metadata) — have
        // settled. Deliberately NOT gated on the ancillary fetches: the entry
        // scroll fires ~0.1s after isLoading flips false, and a slow
        // hook/PR-monitor subscription must not delay the latch past it.
        _ = await (conversation, streamingState)
        latchNewMessagesDividerAnchorIfNeeded()

        _ = await (queue, model, subscriptions, hooks, monitors)
    }

    /// Latch the divider anchor from the current store state. Idempotent:
    /// only the first call derives — a `nil` result is latched too, so no
    /// divider may appear later in the session (re-entry via a later `load()`
    /// never re-derives).
    func latchNewMessagesDividerAnchorIfNeeded() {
        guard !hasLatchedNewMessagesDividerAnchor else { return }
        hasLatchedNewMessagesDividerAnchor = true
        latchedNewMessagesDividerAnchorId = NewMessagesDivider.resolveAnchor(
            messageIds: store.messages.map(\.id),
            lastSeenMessageId: store.lastSeenMessageId
        )
    }

    // MARK: - Seen-marker triggers (agent.markSeen, PROTOCOL §5.5)

    /// Debounce for the "settle" triggers (turn finish, user send) before the
    /// marker advances — the stop-looking boundary bypasses it. Desktop parity
    /// (~1s); tests shorten it.
    var markSeenDebounceDuration: Duration = .seconds(1)

    /// True while the conversation view is on screen (appear/disappear).
    @ObservationIgnored private var isOnScreen = false
    /// True while the app scene is active (`scenePhase == .active`).
    @ObservationIgnored private var isAppActive = true
    @ObservationIgnored private var previousIsStreaming = false
    @ObservationIgnored private var markSeenDebounceTask: Task<Void, Never>?

    /// Re-subscribes the turn-finish trigger to the current store's
    /// `isStreaming` (called from init and whenever `store` is replaced).
    private func observeStreaming() {
        let observedStore = store
        previousIsStreaming = observedStore.isStreaming
        observedStore.onStreamingChanged = { [weak self, weak observedStore] streaming in
            guard let self, let observedStore, store === observedStore else { return }
            let wasStreaming = previousIsStreaming
            previousIsStreaming = streaming
            if wasStreaming, !streaming {
                turnFinished()
            }
        }
    }

    /// Turn finish (`isStreaming` true→false): schedule the debounced
    /// markSeen only while the conversation is on screen and the app is
    /// active — otherwise the user is not looking at the new content.
    private func turnFinished() {
        guard isOnScreen, isAppActive else { return }
        scheduleDebouncedMarkSeen()
    }

    /// View lifecycle: conversation appeared. Entry itself never marks seen —
    /// the "New messages" divider anchor must survive until the user leaves
    /// or the turn finishes (desktop parity).
    func conversationAppeared() {
        isOnScreen = true
    }

    /// Stop-looking boundary: leaving the conversation fires markSeen
    /// IMMEDIATELY, superseding any pending debounce.
    func conversationDisappeared() {
        isOnScreen = false
        fireMarkSeenNow()
    }

    /// Scene-phase mirror of the boundary: backgrounding while the
    /// conversation is on screen fires markSeen immediately; off screen it
    /// just drops any pending debounce.
    func scenePhaseChanged(isActive: Bool) {
        let wasActive = isAppActive
        isAppActive = isActive
        guard wasActive, !isActive else { return }
        if isOnScreen {
            fireMarkSeenNow()
        } else {
            markSeenDebounceTask?.cancel()
            markSeenDebounceTask = nil
        }
    }

    /// One pending debounce at a time — a re-trigger restarts the window.
    /// Dedupe against the current marker lives in `ConversationStore.markSeen`.
    private func scheduleDebouncedMarkSeen() {
        markSeenDebounceTask?.cancel()
        markSeenDebounceTask = Task { [weak self] in
            guard let duration = self?.markSeenDebounceDuration else { return }
            try? await Task.sleep(for: duration)
            guard let self, !Task.isCancelled else { return }
            markSeenDebounceTask = nil
            await store.markSeen(agentId: agentId, workspaceId: workspaceId)
        }
    }

    /// Captures the store (not `self`) so the boundary fire still lands even
    /// if the view model is torn down right after leaving the screen.
    private func fireMarkSeenNow() {
        markSeenDebounceTask?.cancel()
        markSeenDebounceTask = nil
        let store = self.store
        let agentId = self.agentId
        let workspaceId = self.workspaceId
        Task { await store.markSeen(agentId: agentId, workspaceId: workspaceId) }
    }

    func stopAgent(agentId: String) async {
        do {
            _ = try await connection.request(
                "agent.stop",
                params: ["agentId": agentId]
            )
        } catch {
            AppLog.conversation.error("[ConversationViewModel] Failed to stop agent: \(error)")
        }
    }

    /// Fetch the agent's current model and specialist from the backend.
    private func fetchCurrentModel() async {
        do {
            let result = try await connection.request(
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
            AppLog.conversation.error("[ConversationViewModel] Fetch current model failed: \(error)")
        }
    }

    /// Fetch specialist name and description via specialist.list
    private func fetchSpecialistInfo(specialistId: String) async {
        do {
            let result = try await connection.request("specialist.list")
            if let dict = result as? [String: Any],
               let items = dict["specialists"] as? [[String: Any]] {
                if let match = items.first(where: { ($0["id"] as? String) == specialistId }) {
                    specialistName = match["name"] as? String
                    specialistDescription = match["description"] as? String
                }
            }
        } catch {
            AppLog.conversation.error("[ConversationViewModel] Fetch specialist info failed: \(error)")
        }
    }

    // MARK: - Send / Queue

    private enum ComposerImageSelection {
        case explicit([UIImage])
        case pending
    }

    func sendMessage(_ content: String) async {
        await sendMessage(content, imageSelection: .pending)
    }

    func sendMessage(_ content: String, images: [UIImage]) async {
        await sendMessage(content, imageSelection: .explicit(images))
    }

    private func sendMessage(_ content: String, imageSelection: ComposerImageSelection) async {
        let sourceImages: [UIImage]
        let imageRecovery: ComposerImageRecovery
        switch imageSelection {
        case let .explicit(images):
            sourceImages = images
            imageRecovery = .restore(images)
        case .pending:
            sourceImages = pendingImages
            imageRecovery = .preserveCurrentSelection
        }
        let imagePayload: OutgoingImagePayload
        do {
            imagePayload = try await buildImageBlocks(from: sourceImages)
        } catch {
            AppLog.conversation.error("[ConversationViewModel] Image placement failed: \(error)")
            attachmentPipeline.surfaceImagePlacementFailure(
                error,
                content: content,
                imageRecovery: imageRecovery,
                messageText: &messageText
            )
            return
        }
        let filePayload: OutgoingFilePayload
        do {
            filePayload = try await buildFileBlocks(from: pendingFiles)
        } catch {
            AppLog.conversation.error("[ConversationViewModel] File placement failed: \(error)")
            // `pendingFiles` is never pre-cleared by the view, so the files
            // stay attached; restore text + any captured images too.
            attachmentPipeline.surfaceFilePlacementFailure(
                error,
                content: content,
                imageRecovery: imageRecovery,
                messageText: &messageText
            )
            return
        }
        do {
            try await store.sendMessage(
                agentId: agentId,
                content: content,
                workspaceId: workspaceId,
                imagePayload: imagePayload,
                filePayload: filePayload
            )
            // Files rode the send as placed references — release the pending
            // list (and its security-scoped access) only on success.
            clearPendingFiles()
            // Clear draft immediately after successful send
            PersistenceManager.shared.clearDraft(workspaceId: workspaceId, agentId: agentId)
            // User send advances the seen marker on the same debounce as turn
            // finish, with NO focus gate — composing is proof of looking.
            // Success-only: a failed send delivered nothing, so the unseen
            // tail is still unseen (desktop parity — the FE marks seen on the
            // send action's success path).
            scheduleDebouncedMarkSeen()
        } catch {
            AppLog.conversation.error("[ConversationViewModel] Send failed: \(error)")
        }
    }

    func queueMessage(_ content: String) async {
        let imagePayload: OutgoingImagePayload
        do {
            imagePayload = try await buildImageBlocks(from: pendingImages)
        } catch {
            AppLog.conversation.error("[ConversationViewModel] Image placement failed: \(error)")
            // `pendingImages` was never cleared on this path — composer intact.
            attachmentPipeline.surfaceImagePlacementFailure(
                error,
                content: content,
                imageRecovery: .preserveCurrentSelection,
                messageText: &messageText
            )
            return
        }
        let filePayload: OutgoingFilePayload
        do {
            filePayload = try await buildFileBlocks(from: pendingFiles)
        } catch {
            AppLog.conversation.error("[ConversationViewModel] File placement failed: \(error)")
            // `pendingFiles` was never cleared on this path — composer intact.
            attachmentPipeline.surfaceFilePlacementFailure(
                error,
                content: content,
                imageRecovery: .preserveCurrentSelection,
                messageText: &messageText
            )
            return
        }
        do {
            try await store.queueMessage(
                agentId: agentId,
                content: content,
                imagePayload: imagePayload,
                filePayload: filePayload
            )
            pendingImages.removeAll()
            clearPendingFiles()
        } catch {
            AppLog.conversation.error("[ConversationViewModel] Queue failed: \(error)")
        }
    }

    // MARK: - Models

    func renameAgent(_ newName: String) async throws {
        _ = try await connection.request(
            "agent.rename",
            params: [
                "agentId": agentId,
                "name": newName,
                "workspaceId": workspaceId
            ]
        )
        agentName = newName
    }

    // MARK: - Attachments

    func addImage(_ image: UIImage) { attachmentPipeline.addImage(image) }
    func removeImage(at index: Int) { attachmentPipeline.removeImage(at: index) }
    func loadSelectedPhotos() async { await attachmentPipeline.loadSelectedPhotos() }

    var hasPendingAttachments: Bool { attachmentPipeline.hasPendingAttachments }

    func addFiles(_ urls: [URL]) { attachmentPipeline.addFiles(urls) }
    func removePendingFile(at index: Int) { attachmentPipeline.removePendingFile(at: index) }
    func clearPendingFiles() { attachmentPipeline.clearPendingFiles() }

    var isUploadingFiles: Bool { attachmentPipeline.isUploadingFiles }

    func buildImageBlocks(from images: [UIImage]) async throws -> OutgoingImagePayload {
        try await attachmentPipeline.buildImageBlocks(from: images, workspaceId: workspaceId)
    }

    func buildFileBlocks(from files: [PendingFile]) async throws -> OutgoingFilePayload {
        try await attachmentPipeline.buildFileBlocks(from: files, workspaceId: workspaceId)
    }
}
