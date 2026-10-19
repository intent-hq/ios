import Combine
import PhotosUI
import SwiftUI

@MainActor
@Observable class ConversationViewModel {
    var store: ConversationStore {
        didSet {
            if store !== oldValue {
                hasLatchedNewMessagesDividerAnchor = false
                latchedNewMessagesDividerAnchorId = nil
            }
            if let streamingObserverId { oldValue.streamingObservers[streamingObserverId] = nil }
            oldValue.entryObservers[conversationConsumer] = nil
            if activeLiveStoreActivation != nil { oldValue.releaseConversation(conversationConsumer) }
            observeStreaming()
            if activeLiveStoreActivation != nil {
                store.retainConversation(conversationConsumer, agentId: agentId, workspaceId: workspaceId)
            }
        }
    }
    var hookStore: BackgroundHookStore
    var monitoredPrStore: MonitoredPrStore
    let scriptMonitorsStore: WorkspaceScriptMonitorsStore
    var scriptMonitorConsumer: UUID?
    var selectedScriptMonitor: ScriptMonitorSelection?
    @ObservationIgnored let connection: any ConnectionManagerRouting

    let agentId: String
    let workspaceId: String
    var agentName: String
    /// Owned by this conversation, not by a loading stage or retry attempt.
    let loadingStartedAt = Date()

    var isTruncated: Bool { store.isTruncated }
    var totalMessageCount: Int { store.totalMessageCount }
    var hasOlderMessages: Bool { store.hasOlderMessages }
    var isLoadingOlderMessages: Bool { store.isLoadingOlderMessages }
    var olderMessagesError: String? { store.olderMessagesError }

    func loadOlderMessages() async {
        await store.loadOlderMessages()
    }

    var agentNotFound: Bool { store.agentNotFound || workspaceMismatch }
    var workspaceMismatch = false
    var activeAgentHooks: [BackgroundHook] {
        hookStore.activeHooks.filter { $0.agentId == agentId }
    }
    var activeAgentMonitors: [MonitoredPr] {
        monitoredPrStore.activeMonitors.filter { $0.agentId == agentId }
    }
    var newMessagesDividerAnchorId: String? {
        NewMessagesDivider.resolveLatchedAnchor(
            messageIds: store.messages.map(\.id),
            latchedAnchorId: latchedNewMessagesDividerAnchorId
        )
    }

    var latchedNewMessagesDividerAnchorId: String?
    var hasLatchedNewMessagesDividerAnchor = false

    var messageText = "" {
        didSet {
            composerTextRevision &+= 1
            draftTextSubject.send(messageText)
        }
    }
    @ObservationIgnored var composerTextRevision = 0
    var currentModelId: String?
    var currentProviderId: String?
    var currentReasoningEffort: String?
    @ObservationIgnored var modelMetadataGeneration: Int?
    @ObservationIgnored var modelMetadataEpoch: Int?
    var modelCatalogLoadFailed = false
    let optionsStore: CreationOptionsStore
    let agentDetails: AgentDetailStore
    @ObservationIgnored var detailConsumer: UUID?
    var currentSpecialistId: String?
    var specialistName: String? { currentSpecialist?.name }
    var specialistDescription: String? { currentSpecialist?.description }
    private var currentSpecialist: SpecialistInfo? {
        optionsStore.specialists.first { $0.id == currentSpecialistId }
    }
    var dismissQuestionsError: String?

    let attachmentPipeline: ConversationAttachmentPipeline
    @ObservationIgnored var questionAttachmentPipelines: [String: ConversationAttachmentPipeline] = [:]
    var submittingQuestionMessageIds: Set<String> = []
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

    var markSeenDebounceDuration: Duration = .seconds(1)
    @ObservationIgnored var isOnScreen = false
    @ObservationIgnored var isAppActive = true
    @ObservationIgnored var previousIsStreaming = false
    @ObservationIgnored var markSeenDebounceTask: Task<Void, Never>?
    @ObservationIgnored var liveStoreActivationGeneration = 0
    @ObservationIgnored var activeLiveStoreActivation: Int?
    @ObservationIgnored var loadTask: Task<Void, Never>?
    @ObservationIgnored let conversationConsumer = UUID()
    @ObservationIgnored var streamingObserverId: UUID?

    init(
        agentId: String,
        workspaceId: String,
        agentName: String,
        connection: any ConnectionManagerRouting,
        uploadService: AttachmentUploadService,
        optionsStore: CreationOptionsStore,
        agentDetails: AgentDetailStore? = nil,
        conversations: ConversationStorePool? = nil,
        hooks: WorkspaceStatusStore<BackgroundHook>? = nil,
        monitors: WorkspacePrMonitorsStore? = nil,
        scriptMonitors: WorkspaceScriptMonitorsStore? = nil
    ) {
        self.agentId = agentId
        self.workspaceId = workspaceId
        self.agentName = AgentSession.displayName(for: agentName)
        self.connection = connection
        self.optionsStore = optionsStore
        let sharedStore = conversations?.store(agentId: agentId)
        let details = sharedStore?.commands.agentDetails ?? agentDetails ?? AgentDetailStore(connection: connection)
        self.agentDetails = details
        self.store = sharedStore ?? ConversationStore(connectionManager: connection, agentDetails: details)
        self.hookStore = BackgroundHookStore(connectionManager: connection, source: hooks)
        self.monitoredPrStore = MonitoredPrStore(connectionManager: connection, source: monitors)
        self.scriptMonitorsStore = scriptMonitors ?? WorkspaceScriptMonitorsStore(connection: connection)
        self.attachmentPipeline = ConversationAttachmentPipeline(uploadService: uploadService)
        self.messageText = PersistenceManager.shared.loadDraft(
            workspaceId: workspaceId,
            agentId: agentId
        )

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

    isolated deinit {
        releaseOwnedResources()
    }

    private func releaseOwnedResources() {
        deactivateScriptMonitors()
        optionsStore.releaseCatalogs(consumer: conversationConsumer)
        loadTask?.cancel()
        markSeenDebounceTask?.cancel()
        if let streamingObserverId { store.streamingObservers[streamingObserverId] = nil }
        store.entryObservers[conversationConsumer] = nil
        store.releaseConversation(conversationConsumer)
        if let detailConsumer { agentDetails.release(agentId: agentId, consumer: detailConsumer) }
    }
}
