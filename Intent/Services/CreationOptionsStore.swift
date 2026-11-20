import Combine
import Foundation
import Observation

@MainActor
@Observable class CreationOptionsStore {
    let workspaceProviderOptions: WorkspaceProviderOptions
    var specialists: [SpecialistInfo] { specialistCatalog.value ?? [] }
    var providers: [ProviderInfo] = []
    private(set) var loadPhase = LoadPhase.idle
    var isLoading: Bool { loadPhase.isLoading }
    var hasLoaded: Bool { loadPhase.hasLoaded }
    var lastLoadedAt: Date? { loadPhase.lastLoadedAt }
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
    @ObservationIgnored private(set) var latestLoadTask: Task<Void, Never>?
    @ObservationIgnored var latestCreationRefreshTask: Task<Void, Never>?
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
                if !silent { loadPhase = loadPhase.beginning() }
                async let specialistsSucceeded = specialistCatalog.ensure(force: true)
                async let providersSucceeded = fetchProviders(generation: generation, identity: identity)
                let succeeded = await (specialistsSucceeded, providersSucceeded)
                guard generation == loadGeneration, identity == loadIdentity else { return }
                loadPhase = succeeded.0 && succeeded.1
                    ? .loaded(Date())
                    : loadPhase.failing(CreationOptionsLoadError.catalogsUnavailable)
                loadTask = nil
            }
            latestLoadTask = loadTask
        }
        if force || !silent { await loadTask?.value }
    }

    func invalidate() { invalidateCatalogs(clear: true) }

    func cancelUninterestedCreationLoad() {
        guard creationConsumers.isEmpty, loadRequiresInterest else { return }
        loadIdentity = UUID()
        loadTask?.cancel()
        loadTask = nil
        loadPhase = loadPhase.settled()
    }

    func invalidateCatalogs(clear: Bool) {
        workspaceProviderOptions.invalidate()
        loadGeneration &+= 1
        loadTask?.cancel()
        loadTask = nil
        loadPhase = .idle
        providers = []
        specialistCatalog.reset(clear: clear)
        defaultModelProviderCatalog.reset()
        for catalog in modelCatalogs.values { catalog.reset(clear: clear) }
    }

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

private enum CreationOptionsLoadError: LocalizedError {
    case catalogsUnavailable

    var errorDescription: String? { "Creation options could not be loaded." }
}
