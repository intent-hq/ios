import Combine
import Foundation
import Observation

/// BackendSession owns the shared catalogs. Conversation label ensures are
/// independent of the creation picker's explicit provider/auth refreshes.
@MainActor
@Observable class CreationOptionsStore {
    /// Host enablement for workspace and agent creation; conversation model
    /// menus can still load catalogs for existing agents on disabled providers.
    let workspaceProviderOptions: WorkspaceProviderOptions
    var specialists: [SpecialistInfo] { specialistCatalog.value ?? [] }
    var providers: [ProviderInfo] = []
    var isLoading = false
    private(set) var hasLoaded = false
    private(set) var lastLoadedAt: Date?
    /// Connection/reset identity only. Catalog events must not force agent.get.
    private(set) var loadGeneration = 0

    let specialistCatalog: CreationCatalog<SpecialistInfo>
    let defaultModelProviderCatalog: CreationCatalog<String>
    var defaultModelProvider: String? {
        defaultModelProviderCatalog.loadFailed ? nil : defaultModelProviderCatalog.value?.first
    }
    var modelCatalogs: [String: CreationCatalog<ModelInfo>] = [:]
    @ObservationIgnored var creationConsumers: Set<UUID> = []
    @ObservationIgnored var modelConsumers: [UUID: String] = [:]
    @ObservationIgnored var eventHandlerID: UUID?
    @ObservationIgnored var connectionObserver: AnyCancellable?
    @ObservationIgnored var feedObserver: AnyCancellable?
    @ObservationIgnored var observedFeedReady = false
    @ObservationIgnored var previousConnectionState: ConnectionState
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var loadIdentity = UUID()
    @ObservationIgnored private var loadRequiresInterest = false
    @ObservationIgnored private(set) var isActive = true
    let connectionManager: ConnectionManagerRouting

    init(connectionManager: ConnectionManagerRouting = ConnectionManager.shared) {
        self.connectionManager = connectionManager
        previousConnectionState = connectionManager.connectionState
        workspaceProviderOptions = WorkspaceProviderOptions(connectionManager: connectionManager)
        defaultModelProviderCatalog = CreationCatalog {
            let result = try await connectionManager.request("settings.get", params: ["path": "model.defaultProvider"])
            guard let value = (result as? [String: Any])?["value"] as? String,
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CocoaError(.coderReadCorrupt)
            }
            return [value.trimmingCharacters(in: .whitespacesAndNewlines)]
        }
        specialistCatalog = CreationCatalog {
            let result = try await connectionManager.request("specialist.list")
            guard let items = (result as? [String: Any])?["specialists"] as? [[String: Any]] else {
                throw CocoaError(.coderReadCorrupt)
            }
            return items.compactMap { item in
                // Labels historically also accepted a missing description.
                var label = item
                if label["description"] == nil { label["description"] = "" }
                return SpecialistInfo(wire: label)
            }
        }
    }

    isolated deinit {
        if let eventHandlerID { connectionManager.removeEventHandler(id: eventHandlerID) }
        specialistCatalog.reset(releaseConsumers: true)
        defaultModelProviderCatalog.reset(releaseConsumers: true)
        for catalog in modelCatalogs.values { catalog.reset(releaseConsumers: true) }
    }

    /// Explicit creation-picker entry/refresh retains stale-while-revalidate.
    /// Label consumers call ensureSpecialists/ensureModels instead.
    func loadIfNeeded(force: Bool = false, consumer: UUID? = nil) async {
        guard isActive, !Task.isCancelled else { return }
        if let consumer, !creationConsumers.contains(consumer) { return }
        observeSession()
        let silent = hasLoaded
        if consumer == nil { loadRequiresInterest = false }
        if loadTask == nil {
            let generation = loadGeneration
            let identity = UUID()
            loadIdentity = identity
            loadRequiresInterest = consumer != nil
            loadTask = Task { [weak self] in
                guard let self, generation == loadGeneration, identity == loadIdentity else { return }
                if !silent { isLoading = true }
                async let specialistsSucceeded = specialistCatalog.ensure(force: true)
                async let providersSucceeded = fetchProviders(generation: generation, identity: identity)
                let succeeded = await (specialistsSucceeded, providersSucceeded)
                guard generation == loadGeneration, identity == loadIdentity else { return }
                if succeeded.0, succeeded.1 {
                    hasLoaded = true
                    lastLoadedAt = Date()
                }
                isLoading = false
                loadTask = nil
            }
        }
        if force || !silent { await loadTask?.value }
    }

    func invalidate() { invalidateCatalogs(clear: true) }

    func cancelUninterestedCreationLoad() {
        guard creationConsumers.isEmpty, loadRequiresInterest else { return }
        loadIdentity = UUID()
        loadTask?.cancel()
        loadTask = nil
        isLoading = false
    }

    func invalidateCatalogs(clear: Bool) {
        workspaceProviderOptions.invalidate()
        loadGeneration &+= 1
        loadTask?.cancel()
        loadTask = nil
        isLoading = false
        providers = []
        hasLoaded = false
        lastLoadedAt = nil
        specialistCatalog.reset(clear: clear)
        defaultModelProviderCatalog.reset()
        for catalog in modelCatalogs.values { catalog.reset(clear: clear) }
    }

    /// Release all session observers and interests before disconnecting.
    func reset() {
        isActive = false
        invalidate()
        creationConsumers = []
        modelConsumers = [:]
        specialistCatalog.reset(releaseConsumers: true)
        defaultModelProviderCatalog.reset(releaseConsumers: true)
        for catalog in modelCatalogs.values { catalog.reset(releaseConsumers: true) }
        if let eventHandlerID { connectionManager.removeEventHandler(id: eventHandlerID) }
        eventHandlerID = nil
        connectionObserver = nil
        feedObserver = nil
    }

    /// `host.providerAuthStatus` (PROTOCOL §5.14); `authenticated` is
    /// tri-state (true / false / nil unknown). Returns false on transport
    /// error, leaving `providers` unchanged.
    private func fetchProviders(generation: Int, identity: UUID) async -> Bool {
        do {
            guard !Task.isCancelled, identity == loadIdentity else { return false }
            let result = try await connectionManager.request("host.providerAuthStatus")
            guard generation == loadGeneration, identity == loadIdentity, !Task.isCancelled else { return false }
            let items = (result as? [String: Any])?["providers"] as? [[String: Any]] ?? []
            providers = items.compactMap { item -> ProviderInfo? in
                guard let id = item["id"] as? String else { return nil }
                let authentication: ProviderAuthentication
                switch item["authenticated"] as? Bool {
                case true: authentication = .signedIn
                case false: authentication = .signedOut
                case nil: authentication = .unknown
                }
                return ProviderInfo(id: id, authenticated: authentication)
            }
            return true
        } catch {
            AppLog.agents.error("[CreationOptionsStore] host.providerAuthStatus failed: \(error)")
            return false
        }
    }

    // Nil keeps a missing provider catalog distinct from a successfully loaded empty catalog.
    // swiftlint:disable:next discouraged_optional_collection
    func models(for providerId: String) -> [ModelInfo]? { modelCatalogs[providerId]?.value }

    func ensureSpecialists(consumer: UUID? = nil) async {
        guard isActive, !Task.isCancelled else { return }
        observeSession()
        await specialistCatalog.ensure(consumer: consumer)
    }

    func ensureModels(providerId: String, consumer: UUID? = nil) async {
        guard isActive, !Task.isCancelled else { return }
        observeSession()
        await modelCatalog(for: providerId).ensure(consumer: consumer)
    }

    /// User-opened pickers still revalidate warm catalogs. Concurrent callers
    /// share that revalidation; the automatic label path never calls this API.
    func loadModelsIfNeeded(providerId: String, force: Bool = false, consumer: UUID? = nil) async {
        guard isActive, !Task.isCancelled else { return }
        observeSession()
        let catalog = modelCatalog(for: providerId)
        if catalog.value != nil, !force {
            let generation = loadGeneration
            Task { [weak self] in
                guard let self, generation == loadGeneration else { return }
                await catalog.ensure(force: true, consumer: consumer)
            }
        } else {
            await catalog.ensure(force: true, consumer: consumer)
        }
    }

    func modelCatalog(for providerId: String) -> CreationCatalog<ModelInfo> {
        if let catalog = modelCatalogs[providerId] { return catalog }
        let connection = connectionManager
        let catalog = CreationCatalog<ModelInfo> {
            let result = try await connection.request("models.list", params: ["providerId": providerId])
            guard let items = (result as? [String: Any])?["models"] as? [[String: Any]] else {
                throw CocoaError(.coderReadCorrupt)
            }
            return items.compactMap { item in
                guard let id = item["id"] as? String, let name = item["name"] as? String else { return nil }
                return ModelInfo(
                    id: id,
                    name: name,
                    provider: item["provider"] as? String ?? providerId,
                    isDefault: item["isDefault"] as? Bool ?? false,
                    effortLevels: item["effortLevels"] as? [String] ?? []
                )
            }
        }
        modelCatalogs[providerId] = catalog
        return catalog
    }
}
