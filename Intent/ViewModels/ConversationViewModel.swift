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
    var hookStore: BackgroundHookStore
    var monitoredPrStore: MonitoredPrStore
    @ObservationIgnored let connection: any ConnectionManagerRouting

    let agentId: String
    let workspaceId: String
    var agentName: String

    var isTruncated: Bool { store.isTruncated }
    var totalMessageCount: Int { store.totalMessageCount }
    var agentNotFound: Bool { store.agentNotFound }
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
    var availableModels: [ModelInfo] = []
    var currentModelId: String?
    var currentProviderId: String?
    @ObservationIgnored var modelMetadataGeneration: Int?
    var modelCatalogLoadFailed = false
    let optionsStore: CreationOptionsStore
    let agentDetails: AgentDetailStore
    @ObservationIgnored var detailConsumer: UUID?
    var specialistName: String?
    var specialistDescription: String?
    var dismissQuestionsError: String?

    let attachmentPipeline: ConversationAttachmentPipeline
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

    init(
        agentId: String,
        workspaceId: String,
        agentName: String,
        connection: any ConnectionManagerRouting,
        uploadService: AttachmentUploadService,
        optionsStore: CreationOptionsStore,
        agentDetails: AgentDetailStore? = nil
    ) {
        self.agentId = agentId
        self.workspaceId = workspaceId
        self.agentName = agentName
        self.connection = connection
        self.optionsStore = optionsStore
        let details = agentDetails ?? AgentDetailStore(connection: connection)
        self.agentDetails = details
        self.store = ConversationStore(connectionManager: connection, agentDetails: details)
        self.hookStore = BackgroundHookStore(connectionManager: connection)
        self.monitoredPrStore = MonitoredPrStore(connectionManager: connection)
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
        if let detailConsumer { agentDetails.release(agentId: agentId, consumer: detailConsumer) }
    }
}
