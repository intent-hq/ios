import SwiftUI

struct CreateWorkspaceView: View {
    private enum Route: Hashable {
        case branches
        case create
    }

    struct CreationContextRow: Equatable, Identifiable {
        let label: String
        let value: String

        var id: String { label }
    }

    @Environment(AppCoordinator.self) var coordinator
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) var colorScheme

    /// The presenting window's session; all daemon requests (repo/branch
    /// listing, specialist/provider/model options, workspace.create) go
    /// through its connection so pinned windows never hit the default backend.
    private let session: BackendSession
    @State private var navigationPath: [Route] = []
    @State private var selectedRepo: GitHubRepo?
    @State private var selectedBranch: String?
    @State private var branchSearchText = ""
    @State private var completedBranchQuery: String?
    @State private var branchSearchResults: [String] = []
    @State private var branchSearchTask: Task<Void, Never>?
    /// Set once this sheet's own options load — the specialist/provider
    /// lists and the selected provider's first model catalog — has settled,
    /// so a cold load that failed shows the empty state rather than loading
    /// forever, and Create stays disabled until the catalog is resolved.
    @State private var hasSettledOptionsLoad = false
    @State private var selectedSpecialist: SpecialistInfo?
    @State private var selectedProvider: ProviderInfo?
    @State private var selectedModel: ModelInfo?
    @State private var messageText = ""
    @State private var isCreating = false
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var idempotencyKey = UUID().uuidString

    init(session: BackendSession) {
        self.session = session
    }

    /// The session-owned repo cache: it outlives this sheet so a reopen
    /// renders the cached list instantly while it revalidates in the
    /// background.
    private var githubStore: GitHubRepoStore { session.githubRepoStore }
    /// The session-owned specialist / provider / model cache, same contract.
    private var optionsStore: CreationOptionsStore { session.creationOptionsStore }

    /// Specialists offered by the picker: the modal-pickable set with the
    /// orchestrator pinned first, then by name.
    private var specialists: [SpecialistInfo] {
        Self.pickerSpecialists(optionsStore.specialists)
    }
    private var providers: [ProviderInfo] { optionsStore.providers }
    /// The selected provider's cached catalog; empty until loaded, which
    /// hides the model row (the daemon default applies).
    private var models: [ModelInfo] {
        selectedProvider.flatMap { optionsStore.models(for: $0.id) } ?? []
    }
    /// Derived from the store, never a local snapshot: a cache that warms
    /// between construction and the step's load (another sheet, a reconnect
    /// reload) drops the loading state on its own, and a reconnect clear
    /// drives it back on while the store reloads cold.
    private var isLoadingOptions: Bool {
        Self.showsOptionsLoading(
            storeIsLoading: optionsStore.isLoading, storeHasLoaded: optionsStore.hasLoaded,
            settled: hasSettledOptionsLoad)
    }
    /// True while the selected provider's first catalog load is unresolved:
    /// Create stays disabled (as before the cache) so a workspace is never
    /// created before the provider's model choices are known. A warm catalog
    /// is instant and never gates.
    private var isLoadingSelectedModelCatalog: Bool {
        Self.showsModelCatalogLoading(
            catalogCached: selectedProvider.map { optionsStore.models(for: $0.id) != nil },
            settled: hasSettledOptionsLoad)
    }
    /// The branch step's state for the selected repo, owned by the store
    /// (authoritative listing, cached-first paint, cold-load error), never a
    /// local snapshot: another sheet's load, a retry and the reconnect clear
    /// all reach this sheet through it, and nothing here can outlive them.
    private var branchState: GitHubBranchLoadState {
        guard let repo = selectedRepo else { return GitHubBranchLoadState() }
        return githubStore.branchState(owner: repo.owner, repo: repo.name)
    }
    /// Authoritative first (synchronous on a revisit), else the paint.
    private var branchListing: GitHubBranchListing? { branchState.displayed }
    private var branchLoadError: String? { branchState.error }
    private var isLoadingBranches: Bool {
        branchListing == nil && branchLoadError == nil
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            CreateWorkspaceRepoStepView(
                store: githubStore, selectedRepo: $selectedRepo,
                onClose: { dismiss() },
                onNext: { navigationPath.append(.branches) },
                onRepoChanged: resetRepositoryState
            )
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .branches:
                        CreateWorkspaceBranchStepView(
                            repositoryFullName: selectedRepo?.fullName ?? "",
                            displayedBranches: displayedBranches, defaultBranch: branchListing?.defaultBranch,
                            isLoading: isLoadingBranches, loadError: branchLoadError,
                            selectedBranch: $selectedBranch, searchText: $branchSearchText,
                            colorScheme: colorScheme,
                            onRetry: { Task { await fetchBranches() } }, onNext: { navigationPath.append(.create) },
                            onLoad: { await fetchBranches() },
                            onBranchChanged: { idempotencyKey = UUID().uuidString },
                            onSearchTextChanged: scheduleBranchSearch
                        )
                    case .create:
                        CreateWorkspaceSpecialistStepView(
                            repositoryFullName: selectedRepo?.fullName ?? "",
                            branch: selectedBranch ?? "",
                            specialists: specialists, isLoadingSpecialists: isLoadingOptions,
                            selectedSpecialist: $selectedSpecialist,
                            providers: providers,
                            isLoadingProviders: isLoadingOptions || isLoadingSelectedModelCatalog,
                            selectedProvider: $selectedProvider,
                            models: models, selectedModel: $selectedModel,
                            messageText: $messageText,
                            isCreating: isCreating, errorMessage: errorMessage,
                            showError: $showError,
                            colorScheme: colorScheme,
                            onSelectProvider: selectProvider,
                            onCreate: createWorkspace,
                            onLoad: { await fetchCreationOptions() }
                        )
                    }
                }
        }
        // A background revalidation or reconnect reload swaps the cached
        // lists under an open sheet: keep the selections valid against them.
        // Observed by value, not by id, so a same-id metadata change (a
        // provider signing out, a specialist turning hidden, a fresh default
        // preview) reconciles too.
        .onChange(of: optionsStore.specialists) { _, _ in
            reconcileSpecialistSelection()
        }
        .onChange(of: optionsStore.providers) { _, _ in
            Task { await reconcileProviderSelection() }
        }
        .onChange(of: models) { _, models in
            selectedModel = Self.reconciledModel(current: selectedModel, models: models)
        }
        // The cached-first paint, the authoritative listing replacing it and
        // a background revalidation all land here: keep the selection if the
        // new listing still has it, else fall back to default → first.
        .onChange(of: branchListing) { _, listing in
            if let listing { reconcileBranchSelection(with: listing) }
        }
        // A reconnect hard-clears the store — every listing, paint, error,
        // in-flight branch load and the warmed set — whatever this repo held
        // (nothing yet, a paint, an error, a listing): reload and re-warm the
        // selected repo while the branch step is open, so it never sits
        // loading forever on a cleared cache.
        .onChange(of: githubStore.loadGeneration) { _, _ in
            if navigationPath.contains(.branches) {
                Task { await fetchBranches() }
            }
        }
    }

    private func reconcileBranchSelection(with listing: GitHubBranchListing) {
        selectedBranch = Self.preselectedBranch(
            current: selectedBranch,
            branches: Self.orderedBranches(listing.branches, defaultBranch: listing.defaultBranch),
            defaultBranch: listing.defaultBranch
        )
    }

    private var displayedBranches: [String] {
        Self.displayedBranches(
            loaded: branchListing?.branches ?? [], defaultBranch: branchListing?.defaultBranch,
            query: branchSearchText, searchResults: branchSearchResults,
            completedQuery: completedBranchQuery
        )
    }
    private func resetRepositoryState() {
        idempotencyKey = UUID().uuidString
        selectedBranch = nil
        branchSearchTask?.cancel()
        branchSearchText = ""
        completedBranchQuery = nil
        branchSearchResults = []
        // Warm the daemon's repo cache now so the branch step's cached-first
        // paint and the later workspace.create find it fresh (FE parity).
        if let repo = selectedRepo {
            githubStore.warmRepoCache(owner: repo.owner, repo: repo.name)
        }
    }
    /// Store hit: render synchronously and revalidate silently (a failed
    /// refresh keeps the cached listing). Miss: the store paints the daemon's
    /// local cache (`github.branches.listCached`) as soon as it answers while
    /// the authoritative `github.branches.list` loads in parallel, and its
    /// result — or error — wins once it settles. Every load (step open,
    /// retry, reconnect) re-warms the repo cache; the store deduplicates
    /// per connection. Outcomes live in the store, so a repo change simply
    /// stops reading this repo's state.
    private func fetchBranches() async {
        guard let repo = selectedRepo else { return }
        githubStore.warmRepoCache(owner: repo.owner, repo: repo.name)
        if let cached = githubStore.cachedBranchListing(owner: repo.owner, repo: repo.name) {
            // Explicit, not only via onChange: an equal listing for another
            // repo (two repos with just `main`) never fires the observer.
            reconcileBranchSelection(with: cached)
        }
        _ = try? await githubStore.loadBranchListing(
            owner: repo.owner, repo: repo.name, defaultBranch: repo.defaultBranch
        )
    }

    private func scheduleBranchSearch(for text: String) {
        branchSearchTask?.cancel()
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, let repo = selectedRepo else {
            completedBranchQuery = nil
            branchSearchResults = []
            return
        }
        guard query != completedBranchQuery else { return }
        branchSearchTask = Task {
            try? await Task.sleep(for: Constants.CreateWorkspace.branchSearchDebounce)
            guard !Task.isCancelled else { return }
            guard let results = try? await githubStore.fetchRemoteBranches(
                owner: repo.owner, repo: repo.name, prefix: query
            ) else { return }
            guard !Task.isCancelled else { return }
            branchSearchResults = results
            completedBranchQuery = query
        }
    }

    /// Cold (nothing cached): awaits the specialist/provider load while
    /// `isLoadingOptions` shows, then the selected provider's model catalog
    /// with Create disabled; the load settles only once both are resolved
    /// (success or failure). Cached: the pickers already render the cached
    /// lists — the store revalidates in the background and neither loading
    /// state shows.
    private func fetchCreationOptions() async {
        await optionsStore.loadIfNeeded()
        reconcileSpecialistSelection()
        await reconcileProviderSelection()
        hasSettledOptionsLoad = true
    }

    /// Defaults the specialist selection (orchestrator, else first) and
    /// re-defaults or clears it when the selected specialist left the
    /// pickable set.
    private func reconcileSpecialistSelection() {
        selectedSpecialist = Self.preselectedSpecialist(
            current: selectedSpecialist, catalog: optionsStore.specialists)
    }

    /// Defaults the provider selection to a selectable provider (auggie
    /// first) and loads the selected provider's model catalog — instant
    /// when cached, awaited when cold. An explicit model never survives a
    /// provider switch (the daemon default applies), even when the new
    /// provider's catalog shares a bare model id with the old one.
    private func reconcileProviderSelection() async {
        let previousProviderId = selectedProvider?.id
        selectedProvider = Self.preselectedProvider(
            current: selectedProvider, providers: providers)
        guard let provider = selectedProvider else {
            selectedModel = nil
            return
        }
        if provider.id != previousProviderId { selectedModel = nil }
        await optionsStore.loadModelsIfNeeded(providerId: provider.id)
    }

    private func selectProvider(_ provider: ProviderInfo) {
        guard provider.authenticated != false, provider.id != selectedProvider?.id else { return }
        selectedProvider = provider
        selectedModel = nil
        Task {
            await optionsStore.loadModelsIfNeeded(providerId: provider.id)
        }
    }

    /// The picker's specialist list: the modal-pickable set (no hidden or
    /// internal specialists) with the orchestrator pinned first, then by
    /// name.
    static func pickerSpecialists(_ specialists: [SpecialistInfo]) -> [SpecialistInfo] {
        let pickable = specialists.modalPickable
        let orchestratorId = pickable.orchestrator?.id
        return pickable.sorted { a, b in
            let aIsOrchestrator = a.id == orchestratorId
            let bIsOrchestrator = b.id == orchestratorId
            if aIsOrchestrator != bIsOrchestrator { return aIsOrchestrator }
            return a.name < b.name
        }
    }

    /// Keeps the selection while `current`'s id is still pickable in the
    /// unfiltered `catalog`, rebound to the fresh entry so refreshed
    /// metadata (default-model preview) is what the picker shows; otherwise
    /// the orchestrator, else the first pickable specialist, else nil when
    /// the catalog lists nothing pickable (a hidden id must never be
    /// submitted). An empty catalog (cold load or reconnect clear) keeps
    /// `current` so the selection survives the reload.
    static func preselectedSpecialist(
        current: SpecialistInfo?, catalog: [SpecialistInfo]
    ) -> SpecialistInfo? {
        guard !catalog.isEmpty else { return current }
        let specialists = pickerSpecialists(catalog)
        if let current, let fresh = specialists.first(where: { $0.id == current.id }) {
            return fresh
        }
        return specialists.orchestrator ?? specialists.first
    }

    /// The pickers' loading state: shown while the store runs a cold load
    /// (first load or reconnect reload) and before this sheet's first load
    /// has settled on an empty cache; never for a warm cache revalidating,
    /// and not after a settled load that failed (empty state instead).
    static func showsOptionsLoading(
        storeIsLoading: Bool, storeHasLoaded: Bool, settled: Bool
    ) -> Bool {
        storeIsLoading || (!storeHasLoaded && !settled)
    }

    /// Create's model-catalog gate: on while the selected provider's catalog
    /// is not cached (`catalogCached == false`) and this sheet's first load
    /// has not settled; never for a cached catalog (instant path), no
    /// selected provider (nothing to wait on), or after the load settled —
    /// a failed catalog load then falls back to the daemon default.
    static func showsModelCatalogLoading(catalogCached: Bool?, settled: Bool) -> Bool {
        catalogCached == false && !settled
    }

    /// Keeps the selection while `current`'s id is still selectable, rebound
    /// to the fresh entry; otherwise auggie when selectable, else the first
    /// selectable provider, else nil (nothing selectable — the picker shows
    /// setup guidance). An empty list keeps `current` so the selection
    /// survives a reconnect reload.
    static func preselectedProvider(
        current: ProviderInfo?, providers: [ProviderInfo]
    ) -> ProviderInfo? {
        guard !providers.isEmpty else { return current }
        let selectable = providers.filter(\.isSelectable)
        if let current, let fresh = selectable.first(where: { $0.id == current.id }) {
            return fresh
        }
        return selectable.first(where: { $0.id == "auggie" }) ?? selectable.first
    }

    /// Keeps an explicit model only while the displayed catalog still lists
    /// it for the same provider (rebound to the fresh entry); anything else
    /// — the model retired, the catalog cleared, or a provider switch whose
    /// catalog reuses the bare id — falls back to the daemon default (nil).
    static func reconciledModel(current: ModelInfo?, models: [ModelInfo]) -> ModelInfo? {
        guard let current else { return nil }
        return models.first { $0.id == current.id && $0.provider == current.provider }
    }

    static let createRequestTimeout: TimeInterval = 120

    static func creationContextRows(
        repositoryFullName: String,
        branch: String? = nil
    ) -> [CreationContextRow] {
        var rows = [CreationContextRow(label: "Repository", value: repositoryFullName)]
        if let branch {
            rows.append(CreationContextRow(label: "Branch", value: branch))
        }
        return rows
    }

    static func usesExpandedFormLayout(for size: DynamicTypeSize) -> Bool {
        size.isAccessibilitySize
    }

    private func createWorkspace() {
        guard !isCreating, let repo = selectedRepo, let branch = selectedBranch else { return }
        isCreating = true

        Task {
            do {
                let params = Self.buildCreateWorkspaceParams(
                    githubUrl: "https://github.com/\(repo.owner)/\(repo.name)",
                    baseRef: branch,
                    idempotencyKey: idempotencyKey,
                    specialist: selectedSpecialist,
                    provider: selectedProvider,
                    model: selectedModel,
                    message: messageText
                )

                let result = try await session.connection.request(
                    "workspace.create", params: params, timeout: Self.createRequestTimeout)

                if let dict = result as? [String: Any],
                   let wsDict = dict["workspace"] as? [String: Any],
                   let workspace = WorkspaceStore.parseWorkspace(wsDict) {
                    session.workspaceStore.addOrUpdate(workspace)
                    HapticManager.notification(.success)
                    idempotencyKey = UUID().uuidString
                    dismiss()
                    coordinator.onSelectWorkspace(workspace.id)
                } else {
                    errorMessage = "Failed to parse workspace response."
                    showError = true
                }
            } catch {
                errorMessage = error.localizedDescription
                showError = true
            }
            isCreating = false
        }
    }

}