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
    /// Which of this sheet's own loads returned (options; models per
    /// provider), so a cold load that failed shows the empty state or falls
    /// back to the daemon default instead of loading forever, while Create
    /// stays disabled until the selected provider's catalog is resolved.
    /// Published only for loads that returned in the store generation they
    /// started in; a reconnect clear resets every marker.
    @State private var settledLoads = SpecialistPickerView.SettledLoads()
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
        CreationSelectionPolicy.workspacePickerSpecialists(optionsStore.specialists)
    }
    private var providerOptions: WorkspaceProviderOptions { optionsStore.workspaceProviderOptions }
    private var providers: [ProviderInfo] { providerOptions.providers }
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
            storeIsLoading: optionsStore.isLoading,
            storeHasLoaded: optionsStore.hasLoaded,
            settled: settledLoads.options
        )
    }
    /// True while the selected provider's catalog is uncached and this
    /// sheet's load for that provider has not settled: Create stays disabled
    /// (as before the cache) so a workspace is never created before the
    /// provider's model choices are known — per provider, so switching to an
    /// uncached provider re-arms the gate. A warm catalog is instant and
    /// never gates.
    private var isLoadingSelectedModelCatalog: Bool {
        Self.showsModelCatalogLoading(
            catalogCached: selectedProvider.map { optionsStore.models(for: $0.id) != nil },
            settled: selectedProvider.map { settledLoads.modelProviders.contains($0.id) } ?? false
        )
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
        navigationContent
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
            reloadBranchesAfterInvalidation()
        }
        // A reconnect hard-clears the options store too: every settled
        // marker belonged to the dropped cache, so drop them and, while the
        // create step is open, reload (joining the store's own cold reload)
        // and re-warm the selected provider's catalog so Create gates on the
        // fresh load rather than staying enabled on a pre-reconnect one.
        .onChange(of: optionsStore.loadGeneration) { _, _ in
            reloadOptionsAfterInvalidation()
        }
    }

    private var navigationContent: some View {
        NavigationStack(path: $navigationPath) {
            repositoryStep
                .navigationDestination(for: Route.self) { destination(for: $0) }
        }
        // A background revalidation or reconnect reload swaps the cached
        // lists under an open sheet: keep the selections valid against them.
        // Observed by value, not by id, so a same-id metadata change (a
        // provider signing out, a specialist turning hidden, a fresh default
        // preview) reconciles too.
        .onChange(of: optionsStore.specialists) { _, _ in
            reconcileSpecialistSelection()
        }
        // Loading, loaded-empty and failed all project to an empty list;
        // observe the policy state so completed validation still reconciles.
        .onChange(of: providerOptions.state) { _, _ in
            Task { await reconcileProviderSelection() }
        }
        .onChange(of: models) { _, models in
            selectedModel = CreationSelectionPolicy.reconciledModel(current: selectedModel, models: models)
        }
    }

    private func reloadBranchesAfterInvalidation() {
        guard navigationPath.contains(.branches) else { return }
        Task { await fetchBranches() }
    }

    private func reloadOptionsAfterInvalidation() {
        settledLoads.reset()
        guard navigationPath.contains(.create) else { return }
        Task { await fetchCreationOptions() }
    }

    private var repositoryStep: some View {
        CreateWorkspaceRepoStepView(
            store: githubStore,
            selectedRepo: $selectedRepo,
            onClose: { dismiss() },
            onNext: { navigationPath.append(.branches) },
            onRepoChanged: resetRepositoryState
        )
    }

    @ViewBuilder
    private func destination(for route: Route) -> some View {
        switch route {
        case .branches:
            CreateWorkspaceBranchStepView(
                repositoryFullName: selectedRepo?.fullName ?? "",
                displayedBranches: displayedBranches,
                defaultBranch: branchListing?.defaultBranch,
                isLoading: isLoadingBranches,
                loadError: branchLoadError,
                selectedBranch: $selectedBranch,
                searchText: $branchSearchText,
                colorScheme: colorScheme,
                onRetry: { Task { await fetchBranches() } },
                onNext: { navigationPath.append(.create) },
                onLoad: { await fetchBranches() },
                onBranchChanged: { idempotencyKey = UUID().uuidString },
                onSearchTextChanged: scheduleBranchSearch
            )
        case .create:
            CreateWorkspaceSpecialistStepView(
                repositoryFullName: selectedRepo?.fullName ?? "",
                branch: selectedBranch ?? "",
                specialists: specialists,
                isLoadingSpecialists: isLoadingOptions,
                selectedSpecialist: $selectedSpecialist,
                providers: providers,
                isLoadingProviders: isLoadingOptions || providerOptions.isLoading || isLoadingSelectedModelCatalog,
                providerGuidance: providerOptions.guidance,
                selectedProvider: $selectedProvider,
                models: models,
                selectedModel: $selectedModel,
                messageText: $messageText,
                isCreating: isCreating,
                errorMessage: errorMessage,
                showError: $showError,
                colorScheme: colorScheme,
                onSelectProvider: selectProvider,
                onRetryProviders: { Task { await fetchCreationOptions() } },
                onCreate: createWorkspace,
                onLoad: fetchCreationOptions
            )
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
            loaded: branchListing?.branches ?? [],
            defaultBranch: branchListing?.defaultBranch,
            query: branchSearchText,
            searchResults: branchSearchResults,
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
    /// with Create disabled; each settles on its own (success or failure).
    /// Cached: the pickers already render the cached lists — the store
    /// revalidates in the background and neither loading state shows. A load
    /// superseded by a reconnect clear publishes nothing: the
    /// `loadGeneration` change starts a fresh load that settles and reconciles.
    private func fetchCreationOptions() async {
        let generation = optionsStore.loadGeneration
        async let providerLoad: Void = providerOptions.load()
        await optionsStore.loadIfNeeded()
        await providerLoad
        guard settledLoads.settleOptions(startedAt: generation, current: optionsStore.loadGeneration) else {
            return
        }
        reconcileSpecialistSelection()
        await reconcileProviderSelection()
    }

    /// Defaults the specialist selection (orchestrator, else first) and
    /// re-defaults or clears it when the selected specialist left the
    /// pickable set.
    private func reconcileSpecialistSelection() {
        selectedSpecialist = CreationSelectionPolicy.preselectedWorkspaceSpecialist(
            current: selectedSpecialist,
            catalog: optionsStore.specialists
        )
    }

    /// Defaults the provider selection to a selectable provider (auggie
    /// first) and loads the selected provider's model catalog — instant
    /// when cached, awaited when cold. An explicit model never survives a
    /// provider switch (the daemon default applies), even when the new
    /// provider's catalog shares a bare model id with the old one.
    private func reconcileProviderSelection() async {
        CreationSelectionPolicy.reconcileWorkspaceProvider(
            provider: &selectedProvider,
            model: &selectedModel,
            state: providerOptions.state
        )
        guard !providerOptions.isLoading, let provider = selectedProvider else { return }
        await loadModels(for: provider)
    }

    private func selectProvider(_ provider: ProviderInfo) {
        guard providers.contains(provider), provider.isSelectable, provider.id != selectedProvider?.id else { return }
        selectedProvider = provider
        selectedModel = nil
        Task { await loadModels(for: provider) }
    }

    /// Loads the provider's catalog (instant when cached) and settles its
    /// Create gate only when the load returned in the generation it started
    /// in — a completion from before a reconnect clear settles nothing.
    private func loadModels(for provider: ProviderInfo) async {
        let generation = optionsStore.loadGeneration
        await optionsStore.loadModelsIfNeeded(providerId: provider.id)
        settledLoads.settleModels(
            for: provider.id,
            startedAt: generation,
            current: optionsStore.loadGeneration
        )
    }
}

extension CreateWorkspaceView {
    /// The pickers' loading state: shown while the store runs a cold load
    /// (first load or reconnect reload) and before this sheet's first load
    /// has settled on an empty cache; never for a warm cache revalidating,
    /// and not after a settled load that failed (empty state instead).
    static func showsOptionsLoading(
        storeIsLoading: Bool, storeHasLoaded: Bool, settled: Bool
    ) -> Bool {
        storeIsLoading || (!storeHasLoaded && !settled)
    }

    // swiftlint:disable discouraged_optional_boolean
    /// Create's model-catalog gate: on while the selected provider's catalog
    /// is not cached (`catalogCached == false`) and this sheet's load for
    /// that provider has not settled; never for a cached catalog (instant
    /// path), no selected provider (nothing to wait on), or after that
    /// provider's load settled — a failed catalog load then falls back to
    /// the daemon default.
    static func showsModelCatalogLoading(catalogCached: Bool?, settled: Bool) -> Bool {
        catalogCached == false && !settled
    }
    // swiftlint:enable discouraged_optional_boolean

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
        guard !isCreating, canSubmitProvider, let repo = selectedRepo, let branch = selectedBranch else { return }
        isCreating = true

        Task { await performCreateWorkspace(repo: repo, branch: branch) }
    }

    private func performCreateWorkspace(repo: GitHubRepo, branch: String) async {
        // Recheck at the request boundary: a refresh may have removed the
        // selection after the button was tapped but before this task ran.
        guard canSubmitProvider else {
            isCreating = false
            return
        }
        do {
            let params = Self.buildCreateWorkspaceParams(
                githubUrl: "https://github.com/\(repo.owner)/\(repo.name)",
                baseRef: branch,
                idempotencyKey: idempotencyKey,
                initialAgent: InitialAgentInput(
                    specialist: selectedSpecialist,
                    provider: selectedProvider,
                    model: selectedModel,
                    message: messageText
                )
            )
            let result = try await session.connection.request(
                "workspace.create",
                params: params,
                timeout: Self.createRequestTimeout
            )
            if let dictionary = result as? [String: Any],
               let workspaceDictionary = dictionary["workspace"] as? [String: Any],
               let workspace = WorkspaceStore.parseWorkspace(workspaceDictionary) {
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

    private var canSubmitProvider: Bool {
        !Self.isCreateDisabled(
            isCreating: false,
            isLoadingProviders: isLoadingOptions || providerOptions.isLoading || isLoadingSelectedModelCatalog,
            providers: providers,
            selectedProvider: selectedProvider
        )
    }
}
