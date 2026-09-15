import Combine
import Foundation
import Observation

/// Session-lifetime cache of the New Workspace creation options: the
/// specialist catalog (`specialist.list`), provider auth verdicts
/// (`host.providerAuthStatus`) and per-provider model catalogs
/// (`models.list`). Owned by `BackendSession` so a reopened sheet renders
/// the cached lists instantly instead of spinning on three round-trips.
///
/// Same contract as `GitHubRepoStore`: the first `loadIfNeeded()` blocks
/// with `isLoading`; later calls return immediately with the cached lists
/// and revalidate silently in the background (stale-while-revalidate). A
/// reconnect hard-clears the cache and reloads cold, so stale lists never
/// survive a connection flap.
@MainActor
@Observable class CreationOptionsStore {
    /// Unfiltered specialist catalog; pickers apply `modalPickable`.
    var specialists: [SpecialistInfo] = []
    var providers: [ProviderInfo] = []
    /// Model catalogs keyed by provider id; a provider is absent until
    /// `loadModelsIfNeeded(providerId:)` has completed for it.
    private(set) var modelsByProvider: [String: [ModelInfo]] = [:]
    /// True only while a cold (uncached) load is in flight; background
    /// revalidation and model loads never set it.
    var isLoading = false
    /// True once a load completed without a transport error; a failed load
    /// leaves it false so the next `loadIfNeeded()` retries as a cold load.
    private(set) var hasLoaded = false
    private(set) var lastLoadedAt: Date?

    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var modelLoadTasks: [String: Task<Void, Never>] = [:]
    /// Bumped by `invalidate()`: a load captures it on start and every
    /// write after an await is dropped once it no longer matches, so a
    /// completion from before an invalidation cannot repopulate the cache.
    @ObservationIgnored private var loadGeneration = 0
    /// True from the first `loadIfNeeded()` until `invalidate()`, whether
    /// that load is in flight, succeeded or failed — a reconnect re-warms
    /// only a cache the picker has asked for.
    @ObservationIgnored private var hasAttemptedLoad = false
    @ObservationIgnored private var connectionObserver: AnyCancellable?

    private let connectionManager: ConnectionManagerRouting

    init(connectionManager: ConnectionManagerRouting = ConnectionManager.shared) {
        self.connectionManager = connectionManager
        connectionObserver = connectionManager.connectionStatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                if state == .connected {
                    Task { await self?.onConnected() }
                }
            }
    }

    // MARK: - Specialists + providers

    /// Loads the specialist catalog and provider auth verdicts.
    ///
    /// - Cold (nothing cached): awaits the load with `isLoading` set; a
    ///   concurrent call joins the in-flight load.
    /// - Cached and `force == false`: returns immediately and revalidates in
    ///   the background without touching `isLoading` or the cached lists
    ///   (a failed refresh keeps the stale lists).
    /// - `force == true`: refetches; awaited, silent when a cache exists.
    func loadIfNeeded(force: Bool = false) async {
        guard force || !hasLoaded else {
            startLoad(silent: true)
            return
        }
        startLoad(silent: hasLoaded)
        await loadTask?.value
    }

    /// Drops every cached list and the loaded markers so the next
    /// `loadIfNeeded()` runs as a cold load. Loads in flight are superseded:
    /// their completions are dropped (see `loadGeneration`) and they are no
    /// longer joined, so the next call starts a fresh flight.
    func invalidate() {
        loadGeneration &+= 1
        loadTask = nil
        modelLoadTasks = [:]
        hasAttemptedLoad = false
        isLoading = false
        specialists = []
        providers = []
        modelsByProvider = [:]
        hasLoaded = false
        lastLoadedAt = nil
    }

    /// Single-flight: a load already in flight is joined, not duplicated.
    private func startLoad(silent: Bool) {
        hasAttemptedLoad = true
        guard loadTask == nil else { return }
        let generation = loadGeneration
        loadTask = Task { [weak self] in
            await self?.runLoad(silent: silent, generation: generation)
            guard let self, self.loadGeneration == generation else { return }
            self.loadTask = nil
        }
    }

    private func runLoad(silent: Bool, generation: Int) async {
        // The task may first run after an invalidate() that superseded it:
        // touch nothing (an `isLoading` set here would never be cleared).
        guard generation == loadGeneration else { return }
        if !silent { isLoading = true }
        async let specialistsSucceeded = fetchSpecialists(generation: generation)
        async let providersSucceeded = fetchProviders(generation: generation)
        let succeeded = await (specialistsSucceeded, providersSucceeded)
        guard generation == loadGeneration else { return }
        if succeeded.0 && succeeded.1 {
            hasLoaded = true
            lastLoadedAt = Date()
        }
        if !silent { isLoading = false }
    }

    /// A reconnect hard-clears the cache (the daemon's providers or
    /// specialists may have changed underneath it) and reloads cold. With
    /// no load ever requested there is nothing to re-warm until the picker
    /// asks.
    private func onConnected() async {
        guard hasAttemptedLoad else { return }
        invalidate()
        await loadIfNeeded()
    }

    /// `specialist.list` (PROTOCOL §5.11). Returns false on transport
    /// error, leaving `specialists` unchanged so a background refresh keeps
    /// the cached catalog.
    private func fetchSpecialists(generation: Int) async -> Bool {
        do {
            let result = try await connectionManager.request("specialist.list")
            guard generation == loadGeneration else { return false }
            let items = (result as? [String: Any])?["specialists"] as? [[String: Any]] ?? []
            specialists = items.compactMap { SpecialistInfo(wire: $0) }
            return true
        } catch {
            AppLog.agents.error("[CreationOptionsStore] specialist.list failed: \(error)")
            return false
        }
    }

    /// `host.providerAuthStatus` (PROTOCOL §5.14); `authenticated` is
    /// tri-state (true / false / nil unknown). Returns false on transport
    /// error, leaving `providers` unchanged.
    private func fetchProviders(generation: Int) async -> Bool {
        do {
            let result = try await connectionManager.request("host.providerAuthStatus")
            guard generation == loadGeneration else { return false }
            let items = (result as? [String: Any])?["providers"] as? [[String: Any]] ?? []
            providers = items.compactMap { item in
                guard let id = item["id"] as? String else { return nil }
                return ProviderInfo(id: id, authenticated: item["authenticated"] as? Bool)
            }
            return true
        } catch {
            AppLog.agents.error("[CreationOptionsStore] host.providerAuthStatus failed: \(error)")
            return false
        }
    }

    // MARK: - Models

    /// The cached `models.list` catalog for `providerId`, or nil when it has
    /// not been loaded yet.
    func models(for providerId: String) -> [ModelInfo]? {
        modelsByProvider[providerId]
    }

    /// Loads `models.list` for `providerId` with the same cold / cached /
    /// forced semantics as `loadIfNeeded(force:)`, single-flight per
    /// provider. Never touches `isLoading`: the picker gates on the provider
    /// load and shows the model row as soon as its catalog is cached.
    func loadModelsIfNeeded(providerId: String, force: Bool = false) async {
        guard force || modelsByProvider[providerId] == nil else {
            startModelLoad(providerId: providerId)
            return
        }
        startModelLoad(providerId: providerId)
        await modelLoadTasks[providerId]?.value
    }

    private func startModelLoad(providerId: String) {
        guard modelLoadTasks[providerId] == nil else { return }
        let generation = loadGeneration
        modelLoadTasks[providerId] = Task { [weak self] in
            await self?.fetchModels(providerId: providerId, generation: generation)
            guard let self, self.loadGeneration == generation else { return }
            self.modelLoadTasks[providerId] = nil
        }
    }

    /// Best-effort: a transport error leaves the provider's cached catalog
    /// (if any) unchanged, so the next `loadModelsIfNeeded` retries cold.
    private func fetchModels(providerId: String, generation: Int) async {
        guard generation == loadGeneration else { return }
        do {
            let result = try await connectionManager.request(
                "models.list", params: ["providerId": providerId])
            guard generation == loadGeneration else { return }
            let items = (result as? [String: Any])?["models"] as? [[String: Any]] ?? []
            modelsByProvider[providerId] = items.compactMap { item in
                guard let id = item["id"] as? String,
                      let name = item["name"] as? String else { return nil }
                return ModelInfo(
                    id: id,
                    name: name,
                    provider: item["provider"] as? String ?? providerId,
                    isDefault: item["isDefault"] as? Bool ?? false
                )
            }
        } catch {
            AppLog.agents.error("[CreationOptionsStore] models.list failed for \(providerId): \(error)")
        }
    }
}
