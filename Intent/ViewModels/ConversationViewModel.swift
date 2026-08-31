import Combine
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable class ConversationViewModel {
    var store = ConversationStore() {
        didSet {
            oldValue.onStreamingChanged = nil
            observeStreaming()
        }
    }
    /// Live background hooks for this conversation's workspace (PROTOCOL §5.40).
    var hookStore = BackgroundHookStore()
    /// Live PR monitors for this conversation's workspace (PROTOCOL §5.42).
    var monitoredPrStore = MonitoredPrStore()

    let agentId: String
    let workspaceId: String
    var agentName: String

    var messages: [ConversationMessage] { store.messages }

    /// All transcript messages — nothing is display-filtered anymore.
    /// Event-notification wakes render as a compact event-wake banner and
    /// agent-to-agent sends (`metadata.type == "agent_message"`) render with
    /// a sender attribution header (FE parity: ChatPanel.svelte /
    /// ChatMessage.svelte), so MessageView owns all automated-row rendering.
    var filteredMessages: [ConversationMessage] {
        store.messages
    }
    var isStreaming: Bool { store.isStreaming }
    var isLoading: Bool { store.isLoading }
    /// Display-only filter: show only user-authored entries in the
    /// queued-messages section — daemon-originated wakes (hook, PR-monitor,
    /// event-notification) and agent-to-agent sends are hidden. The store
    /// keeps the full queue and flush behavior is unchanged.
    var queuedMessages: [QueuedMessage] {
        store.queuedMessages.filter { $0.isUserMessage }
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

    /// Id of the message the "New messages" divider renders after, or nil
    /// when hidden. Applies the latched per-session anchor against the
    /// current transcript (PROTOCOL §5.5 seen marker; FE parity:
    /// new-messages-divider.ts): a latched `nil` hides the divider for the
    /// whole viewing session, and an anchor that left the transcript (e.g.
    /// `agent.editAndRegenerate` truncation) hides it WITHOUT re-deriving.
    var newMessagesDividerAnchorId: String? {
        NewMessagesDivider.resolveLatchedAnchor(
            messageIds: store.messages.map(\.id),
            latchedAnchorId: latchedNewMessagesDividerAnchorId)
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

    // Image attachments
    var pendingImages: [UIImage] = []
    var selectedPhotoItems: [PhotosPickerItem] = []

    // File attachments (picked via fileImporter; uploaded at send time)
    var pendingFiles: [PendingFile] = []
    /// URLs whose `startAccessingSecurityScopedResource()` succeeded and owe a
    /// balancing stop. Stored (not derived from `pendingFiles`) so the
    /// nonisolated deinit can read it — @Observable rewrites `pendingFiles`
    /// into a computed property that deinit cannot touch.
    @ObservationIgnored private var securityScopedURLs: [URL] = []

    @ObservationIgnored private let draftTextSubject = PassthroughSubject<String, Never>()
    @ObservationIgnored private var draftSaveCancellable: AnyCancellable?

    /// Places composer attachments into the workspace's attachment registry
    /// at send time (PROTOCOL §5.9). Test seam: inject a service backed by a
    /// `FakeConnectionManager`.
    @ObservationIgnored var uploadService: AttachmentUploadService = .shared

    init(agentId: String, workspaceId: String, agentName: String) {
        self.agentId = agentId
        self.workspaceId = workspaceId
        self.agentName = agentName

        // Restore saved draft
        self.messageText = PersistenceManager.shared.loadDraft(
            workspaceId: workspaceId, agentId: agentId)

        // Debounced draft saving (0.5s)
        draftSaveCancellable = draftTextSubject
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self] text in
                guard let self = self else { return }
                PersistenceManager.shared.saveDraft(
                    text, workspaceId: self.workspaceId, agentId: self.agentId)
            }

        observeStreaming()
    }

    deinit {
        // deinit is nonisolated: stop any security-scoped access still owed.
        // `stopAccessingSecurityScopedResource` is safe to call off-main.
        for url in securityScopedURLs {
            url.stopAccessingSecurityScopedResource()
        }
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
            lastSeenMessageId: store.lastSeenMessageId)
    }

    /// Tears down the live-store subscriptions (background hooks + PR
    /// monitors) when the conversation leaves the screen (`load()`
    /// re-subscribes on the next appearance).
    func teardownLiveStores() async {
        await hookStore.unsubscribe()
        await monitoredPrStore.unsubscribe()
    }

    // MARK: - Seen-marker triggers (agent.markSeen, PROTOCOL §5.5)

    /// Debounce for the "settle" triggers (turn finish, user send) before the
    /// marker advances — the stop-looking boundary bypasses it. Desktop parity
    /// (~1s); tests shorten it.
    var markSeenDebounceNanos: UInt64 = 1_000_000_000

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
            guard let self, let observedStore, self.store === observedStore else { return }
            let wasStreaming = self.previousIsStreaming
            self.previousIsStreaming = streaming
            if wasStreaming && !streaming {
                self.turnFinished()
            }
        }
    }

    /// Turn finish (`isStreaming` true→false): schedule the debounced
    /// markSeen only while the conversation is on screen and the app is
    /// active — otherwise the user is not looking at the new content.
    private func turnFinished() {
        guard isOnScreen && isAppActive else { return }
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
            guard let nanos = self?.markSeenDebounceNanos else { return }
            try? await Task.sleep(nanoseconds: nanos)
            guard let self = self, !Task.isCancelled else { return }
            self.markSeenDebounceTask = nil
            await self.store.markSeen(agentId: self.agentId, workspaceId: self.workspaceId)
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

    func cancelWait() async {
        await store.cancelSubscriptions(agentId: agentId, workspaceId: workspaceId)
    }

    func stopAgent(agentId: String) async {
        do {
            let _ = try await ConnectionManager.shared.request(
                "agent.stop", params: ["agentId": agentId])
        } catch {
            AppLog.conversation.error("[ConversationViewModel] Failed to stop agent: \(error)")
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
            AppLog.conversation.error("[ConversationViewModel] Fetch current model failed: \(error)")
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
            AppLog.conversation.error("[ConversationViewModel] Fetch specialist info failed: \(error)")
        }
    }

    // MARK: - Send / Queue

    func sendMessage(_ content: String, images: [UIImage]? = nil) async {
        let sourceImages = images ?? pendingImages
        let imageBlocks: [[String: Any]]?
        do {
            imageBlocks = try await buildImageBlocks(from: sourceImages)
        } catch {
            AppLog.conversation.error("[ConversationViewModel] Image placement failed: \(error)")
            surfacePlacementFailure(error, content: content,
                                    images: images != nil ? sourceImages : nil)
            return
        }
        let fileBlocks: [[String: Any]]?
        do {
            fileBlocks = try await buildFileBlocks(from: pendingFiles)
        } catch {
            AppLog.conversation.error("[ConversationViewModel] File placement failed: \(error)")
            // `pendingFiles` is never pre-cleared by the view, so the files
            // stay attached; restore text + any captured images too.
            surfaceFilePlacementFailure(error, content: content,
                                        images: images != nil ? sourceImages : nil)
            return
        }
        do {
            try await store.sendMessage(agentId: agentId, content: content, workspaceId: workspaceId, imageBlocks: imageBlocks, fileBlocks: fileBlocks)
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

    /// Send a suggested prompt as-is: prompt text only. Unlike `sendMessage`,
    /// this never attaches `pendingImages` and never clears the persisted
    /// composer draft — the in-progress draft (text + attachments) stays
    /// intact for the user's own message.
    func sendSuggestedPrompt(_ prompt: String) async {
        do {
            try await store.sendMessage(agentId: agentId, content: prompt, workspaceId: workspaceId)
        } catch {
            AppLog.conversation.error("[ConversationViewModel] Send suggested prompt failed: \(error)")
        }
    }

    func queueMessage(_ content: String) async {
        let imageBlocks: [[String: Any]]?
        do {
            imageBlocks = try await buildImageBlocks(from: pendingImages)
        } catch {
            AppLog.conversation.error("[ConversationViewModel] Image placement failed: \(error)")
            // `pendingImages` was never cleared on this path — composer intact.
            surfacePlacementFailure(error, content: content, images: nil)
            return
        }
        let fileBlocks: [[String: Any]]?
        do {
            fileBlocks = try await buildFileBlocks(from: pendingFiles)
        } catch {
            AppLog.conversation.error("[ConversationViewModel] File placement failed: \(error)")
            // `pendingFiles` was never cleared on this path — composer intact.
            surfaceFilePlacementFailure(error, content: content, images: nil)
            return
        }
        do {
            try await store.queueMessage(agentId: agentId, content: content, imageBlocks: imageBlocks, fileBlocks: fileBlocks)
            pendingImages.removeAll()
            clearPendingFiles()
        } catch {
            AppLog.conversation.error("[ConversationViewModel] Queue failed: \(error)")
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
            AppLog.conversation.error("[ConversationViewModel] Edit queued message failed: \(error)")
        }
    }

    func removeQueuedMessage(messageId: String) async {
        do {
            try await store.removeQueuedMessage(agentId: agentId, messageId: messageId)
        } catch {
            AppLog.conversation.error("[ConversationViewModel] Remove queued message failed: \(error)")
        }
    }

    func sendQueuedMessageNow(messageId: String) async {
        do {
            try await store.sendQueuedMessageNow(agentId: agentId, messageId: messageId, workspaceId: workspaceId)
        } catch {
            AppLog.conversation.error("[ConversationViewModel] Send now failed: \(error)")
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
            AppLog.conversation.error("[ConversationViewModel] Fetch models failed: \(error)")
        }
    }

    func setModel(_ modelId: String) async {
        do {
            try await store.setModel(agentId: agentId, modelId: modelId, workspaceId: workspaceId)
            currentModelId = modelId
        } catch {
            AppLog.conversation.error("[ConversationViewModel] Set model failed: \(error)")
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

    // MARK: - File attachments

    /// True when the composer has any attachment pending (images or files) —
    /// drives send-button enablement alongside non-empty text.
    var hasPendingAttachments: Bool {
        !pendingImages.isEmpty || !pendingFiles.isEmpty
    }

    /// Add picked file URLs (from `.fileImporter`) to the pending list.
    /// Starts security-scoped access per URL so the file stays readable until
    /// it is removed or uploaded at send time; duplicates (same URL already
    /// pending) are skipped.
    func addFiles(_ urls: [URL]) {
        for url in urls {
            guard !pendingFiles.contains(where: { $0.url == url }) else { continue }
            let accessing = url.startAccessingSecurityScopedResource()
            if accessing {
                securityScopedURLs.append(url)
            }
            let values = try? url.resourceValues(forKeys: [.nameKey, .fileSizeKey])
            pendingFiles.append(PendingFile(
                url: url,
                displayName: values?.name ?? url.lastPathComponent,
                size: (values?.fileSize).map(Int64.init)
            ))
        }
    }

    func removePendingFile(at index: Int) {
        guard pendingFiles.indices.contains(index) else { return }
        let file = pendingFiles.remove(at: index)
        stopSecurityScopedAccess(for: file.url)
    }

    func clearPendingFiles() {
        let urls = pendingFiles.map(\.url)
        pendingFiles.removeAll()
        for url in urls {
            stopSecurityScopedAccess(for: url)
        }
    }

    private func stopSecurityScopedAccess(for url: URL) {
        guard let ledgerIndex = securityScopedURLs.firstIndex(of: url) else { return }
        securityScopedURLs.remove(at: ledgerIndex)
        url.stopAccessingSecurityScopedResource()
    }

    /// The daemon's per-image cap for attachment-reference image blocks
    /// (30 MiB decoded, PROTOCOL §5.5 — monorepo#3338).
    static let maxImageReferenceBytes = 30 * 1024 * 1024

    /// An image the send/queue path could not place into the attachment
    /// registry — the message is NOT sent (FE parity: fail-closed, images are
    /// never silently dropped or partially sent).
    enum ImagePlacementError: LocalizedError {
        /// JPEG encoding produced no data. 1-based index for the user
        /// message.
        case encodingFailed(index: Int)
        /// The encoded payload exceeds the daemon's 30 MiB per-image
        /// reference cap. 1-based index for the user message.
        case imageTooLarge(index: Int)
        /// The encoded payloads together exceed the daemon's 30 MiB
        /// aggregate cap across all image blocks in one message.
        case imagesTooLarge

        /// `file.placeAttachment` / the chunked upload session failed.
        case placementFailed(index: Int, underlying: Error)

        var errorDescription: String? {
            switch self {
            case .encodingFailed(let index):
                return "Image \(index) could not be encoded for sending."
            case .imageTooLarge(let index):
                return "Image \(index) is too large to send (over 30 MiB as JPEG)."
            case .imagesTooLarge:
                return "The attached images are too large to send together (over 30 MiB total as JPEG)."
            case .placementFailed(let index, let underlying):
                return "Image \(index) could not be uploaded. \(underlying.localizedDescription)"
            }
        }
    }

    /// Place each image into the workspace's attachment registry and build
    /// `{ type: "image", attachmentId, mimeType }` reference blocks
    /// (PROTOCOL §5.5, monorepo#3338) — inline base64 never rides the send.
    /// The daemon enforces the 30 MiB cap per image AND in aggregate across
    /// a message's blocks, so both are checked before any placement.
    /// FAIL-CLOSED: any encoding/placement failure throws
    /// `ImagePlacementError` (FE parity: `toImageReferenceBlocks`).
    func buildImageBlocks(from images: [UIImage]) async throws -> [[String: Any]]? {
        guard !images.isEmpty else { return nil }
        var payloads: [Data] = []
        for (index, image) in images.enumerated() {
            guard let data = image.jpegData(compressionQuality: 0.8) else {
                throw ImagePlacementError.encodingFailed(index: index + 1)
            }
            guard data.count <= Self.maxImageReferenceBytes else {
                throw ImagePlacementError.imageTooLarge(index: index + 1)
            }
            payloads.append(data)
        }
        guard payloads.reduce(0, { $0 + $1.count }) <= Self.maxImageReferenceBytes else {
            throw ImagePlacementError.imagesTooLarge
        }
        var blocks: [[String: Any]] = []
        for (index, data) in payloads.enumerated() {
            let placed: AttachmentUploadService.PlacedAttachment
            do {
                placed = try await uploadService.placeData(
                    workspaceId: workspaceId,
                    fileName: "image-\(Int(Date().timeIntervalSince1970 * 1000))-\(index + 1).jpg",
                    data: data,
                    mimeType: "image/jpeg")
            } catch {
                throw ImagePlacementError.placementFailed(index: index + 1, underlying: error)
            }
            blocks.append([
                "type": "image",
                "attachmentId": placed.attachmentId,
                "mimeType": placed.mimeType ?? "image/jpeg",
            ])
        }
        return blocks
    }

    /// User-facing message for a failed image placement (the send was
    /// aborted; nothing reached the daemon). Nil when there is nothing to
    /// surface. The view presents it as a non-destructive alert.
    var imagePlacementError: String?

    /// Surface a placement failure and restore the composer: the send text
    /// returns to the draft and explicitly captured images (cleared from
    /// `pendingImages` by `MessageInputView` before the async send) are
    /// re-attached so nothing is lost.
    private func surfacePlacementFailure(_ error: Error, content: String, images: [UIImage]?) {
        imagePlacementError = error.localizedDescription
        if messageText.isEmpty {
            messageText = content
        }
        if let images, pendingImages.isEmpty {
            pendingImages = images
        }
    }

    // MARK: - File placement (send-time uploads)

    /// A file the send/queue path could not place into the attachment
    /// registry — the message is NOT sent (fail-closed, same discipline as
    /// `ImagePlacementError`: files are never silently dropped or partially
    /// sent).
    enum FilePlacementError: LocalizedError {
        /// The file exceeds the daemon's 1 GiB per-attachment cap
        /// (`AttachmentUploadService.maxAttachmentBytes`, PROTOCOL §5.9).
        case fileTooLarge(name: String)
        /// `file.placeAttachment` / the chunked upload session failed, or
        /// the file could not be read.
        case placementFailed(name: String, underlying: Error)

        var errorDescription: String? {
            switch self {
            case .fileTooLarge(let name):
                return "\"\(name)\" is too large to send (over 1 GiB)."
            case .placementFailed(let name, let underlying):
                return "\"\(name)\" could not be uploaded. \(underlying.localizedDescription)"
            }
        }
    }

    /// Per-pending-file upload progress, keyed by `PendingFile.id` — set only
    /// while a send/queue is placing that file (chunked > 25 MB uploads
    /// report fractional progress; single-shot flips 0 → 1). The composer
    /// chips read this to show a spinner/progress state.
    var fileUploadProgress: [UUID: Double] = [:]

    /// True while `buildFileBlocks` is placing pending files — drives chip
    /// spinners and lets the composer disable removal mid-upload.
    var isUploadingFiles: Bool { !fileUploadProgress.isEmpty }

    /// Place each pending file into the workspace's attachment registry
    /// (streaming off disk; chunked above 25 MB) and build
    /// `{ type: "file", attachmentId, fileName, mimeType?, size }` reference
    /// blocks (PROTOCOL §5.5). FAIL-CLOSED: any placement failure throws
    /// `FilePlacementError` and the message is not sent. Does NOT clear
    /// `pendingFiles` — callers clear on successful send only.
    func buildFileBlocks(from files: [PendingFile]) async throws -> [[String: Any]]? {
        guard !files.isEmpty else { return nil }
        for file in files {
            fileUploadProgress[file.id] = 0
        }
        defer { fileUploadProgress.removeAll() }
        var blocks: [[String: Any]] = []
        for file in files {
            if let size = file.size, size > Int64(AttachmentUploadService.maxAttachmentBytes) {
                throw FilePlacementError.fileTooLarge(name: file.displayName)
            }
            let placed: AttachmentUploadService.PlacedAttachment
            do {
                placed = try await uploadService.placeFile(
                    workspaceId: workspaceId,
                    fileName: file.displayName,
                    fileURL: file.url,
                    mimeType: Self.mimeType(for: file.url),
                    onProgress: { [weak self] fraction in
                        self?.fileUploadProgress[file.id] = fraction
                    })
            } catch AttachmentUploadService.UploadError.payloadTooLarge {
                throw FilePlacementError.fileTooLarge(name: file.displayName)
            } catch {
                throw FilePlacementError.placementFailed(name: file.displayName, underlying: error)
            }
            fileUploadProgress[file.id] = 1
            var block: [String: Any] = [
                "type": "file",
                "attachmentId": placed.attachmentId,
                "fileName": placed.fileName,
                "size": placed.size,
            ]
            if let mimeType = placed.mimeType {
                block["mimeType"] = mimeType
            }
            blocks.append(block)
        }
        return blocks
    }

    /// MIME type inferred from the file extension via UTType, nil when
    /// unknown (the daemon then stores the attachment without a mimeType).
    static func mimeType(for url: URL) -> String? {
        UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
    }

    /// User-facing message for a failed file placement (the send was
    /// aborted; nothing reached the daemon). Nil when there is nothing to
    /// surface. The view presents it as a non-destructive alert.
    var filePlacementError: String?

    /// Surface a file-placement failure and restore the composer. Pending
    /// files were never cleared (clearing happens only after a successful
    /// send), so only text — and captured images on the explicit-images send
    /// path — need restoring.
    private func surfaceFilePlacementFailure(_ error: Error, content: String, images: [UIImage]?) {
        filePlacementError = error.localizedDescription
        if messageText.isEmpty {
            messageText = content
        }
        if let images, pendingImages.isEmpty {
            pendingImages = images
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
            AppLog.conversation.error("[ConversationViewModel] Submit question answers failed: \(error)")
            store.rollbackFailedSend()
        }
    }

    /// User-facing message for a failed `agent.dismissQuestions`
    /// (intent-hq/monorepo#1800) — the view presents it as a non-destructive
    /// alert. Nil when there is nothing to surface.
    var dismissQuestionsError: String?

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
            AppLog.conversation.error("[ConversationViewModel] Dismiss questions failed: \(error)")
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
        // The same message-level scan the views use for stripping (empty
        // join like the desktop, so mid-line splits reassemble): prompts and
        // stripping come from one scan and can never disagree
        // (intent-hq/intent#3936; see `SuggestedPrompts.parse(contentBlocks:)`).
        return SuggestedPrompts.parse(contentBlocks: lastMessage.contentBlocks ?? []).prompts
    }
}

/// A file picked from the Files app, pending in the composer until send time
/// (uploads happen at send, not at pick). Security-scoped access lifecycle is
/// owned by `ConversationViewModel` (started in `addFiles`, stopped on
/// remove/clear/deinit), not by this value.
struct PendingFile: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let displayName: String
    let size: Int64?

    /// Human-readable size for the composer chip (e.g. "1.2 MB"), nil when
    /// the size could not be read at pick time.
    var formattedSize: String? {
        guard let size else { return nil }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

