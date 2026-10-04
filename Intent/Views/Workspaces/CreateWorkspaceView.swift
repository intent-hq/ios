import SwiftUI

struct CreateWorkspaceView: View {
    private typealias Route = WorkspaceCreationDraft.Route

    @Environment(AppCoordinator.self) var coordinator
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) var colorScheme

    /// The presenting window's session; all daemon requests (repo/branch
    /// listing, specialist/provider/model options, workspace.create) go
    /// through its connection so pinned windows never hit the default backend.
    private let session: BackendSession
    @State private var form: WorkspaceCreationDraft
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
    @State private var isCreating = false
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var catalogConsumer = UUID()
    @State private var catalogIsVisible = true

    init(session: BackendSession) {
        self.session = session
        _form = State(initialValue: session.workspaceCreationDraft ?? WorkspaceCreationDraft(backendID: session.backendID, persistence: .shared))
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
        form.agentSelection.provider.flatMap { optionsStore.models(for: $0.id) } ?? []
    }
    private var reasoningLevels: [String] {
        CreationSelectionPolicy.workspaceReasoningLevels(
            provider: form.agentSelection.provider, model: form.agentSelection.model, models: models
        )
    }
    private var validatedReasoningEffort: String? {
        CreationSelectionPolicy.reconciledReasoningEffort(
            current: form.agentSelection.reasoningEffort, effortLevels: reasoningLevels
        )
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
            catalogCached: form.agentSelection.provider.map { optionsStore.models(for: $0.id) != nil },
            settled: form.agentSelection.provider.map { settledLoads.modelProviders.contains($0.id) } ?? false
        )
    }
    /// The branch step's state for the selected repo, owned by the store
    /// (authoritative listing, cached-first paint, cold-load error), never a
    /// local snapshot: another sheet's load, a retry and the reconnect clear
    /// all reach this sheet through it, and nothing here can outlive them.
    private var branchState: GitHubBranchLoadState {
        guard let repo = form.selectedRepo else { return GitHubBranchLoadState() }
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
        .onAppear { catalogIsVisible = true }
        .onDisappear {
            session.workspaceCreationDraft = form.resumable
            catalogIsVisible = false
            optionsStore.releaseCatalogs(consumer: catalogConsumer)
            form.images.cancelImport()
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
        NavigationStack(path: $form.navigationPath) {
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
            form.agentSelection.reconcileModels(models)
        }
        .onChange(of: reasoningLevels) { _, _ in
            form.agentSelection.reconcileReasoning(effortLevels: reasoningLevels)
        }
    }

    private func reloadBranchesAfterInvalidation() {
        guard form.navigationPath.contains(.branches) else { return }
        Task { await fetchBranches() }
    }

    private func reloadOptionsAfterInvalidation() {
        settledLoads.reset()
        guard form.navigationPath.contains(.create) else { return }
        Task { await fetchCreationOptions() }
    }
}

extension CreateWorkspaceView {
    private var repositoryStep: some View {
        let createRepository = {
            form.navigationPath.append(.newRepository)
        }
        return CreateWorkspaceRepoStepView(
            store: githubStore,
            selectedRepo: $form.selectedRepo,
            onClose: { dismiss() },
            onNext: { form.navigationPath.append(.branches) },
            onRepoChanged: resetRepositoryState,
            onCreateRepository: createRepository
        )
    }

    private var newRepositoryStep: some View {
        let advance: (String) -> Void = { path in
            form.newRepositoryPath = path
            form.navigationPath.append(.create)
        }
        return CreateWorkspaceNewRepoView(
            draft: $form.newRepositoryDraft,
            connection: session.connection,
            attempts: form.creationAttempts,
            onBack: { form.navigationPath.removeLast() },
            onNext: advance
        )
    }

    @ViewBuilder
    private func destination(for route: Route) -> some View {
        switch route {
        case .newRepository:
            newRepositoryStep
        case .branches:
            branchStep
        case .create:
            CreateWorkspaceSpecialistStepView(
                repositoryFullName: form.navigationPath.contains(.newRepository) ? (form.newRepositoryPath ?? "") : (form.selectedRepo?.fullName ?? ""),
                branch: form.navigationPath.contains(.newRepository) ? nil : form.selectedBranch,
                specialists: specialists,
                isLoadingSpecialists: isLoadingOptions,
                selectedSpecialist: Binding(get: { form.agentSelection.specialist }, set: { form.agentSelection.selectSpecialist($0) }),
                providers: providers,
                isLoadingProviders: isLoadingOptions || providerOptions.isLoading || isLoadingSelectedModelCatalog,
                providerGuidance: providerOptions.guidance,
                selectedProvider: form.agentSelection.provider,
                models: models,
                selectedModel: Binding(get: { form.agentSelection.model }, set: { form.agentSelection.selectModel($0) }),
                reasoningLevels: reasoningLevels,
                selectedReasoningEffort: Binding(get: { form.agentSelection.reasoningEffort }, set: { form.agentSelection.selectReasoning($0) }),
                messageText: $form.messageText,
                images: form.images,
                isCreating: isCreating,
                allowsCreation: coordinator.canCreateWorkspace,
                errorMessage: errorMessage,
                showError: $showError,
                colorScheme: colorScheme,
                onSelectProvider: selectProvider,
                onRetryProviders: { Task { await fetchCreationOptions() } },
                onBack: {
                    guard !isCreating, form.navigationPath.last == .create else { return }
                    form.navigationPath.removeLast()
                },
                onCreate: createWorkspace,
                onLoad: fetchCreationOptions
            )
        }
    }

    private var branchStep: some View {
        CreateWorkspaceBranchStepView(
            repositoryFullName: form.selectedRepo?.fullName ?? "",
            displayedBranches: displayedBranches,
            defaultBranch: branchListing?.defaultBranch,
            isLoading: isLoadingBranches,
            loadError: branchLoadError,
            selectedBranch: $form.selectedBranch,
            searchText: $branchSearchText,
            colorScheme: colorScheme,
            onRetry: { Task { await fetchBranches() } },
            onNext: { form.navigationPath.append(.create) },
            onLoad: { await fetchBranches() },
            onSearchTextChanged: scheduleBranchSearch
        )
    }

    private func reconcileBranchSelection(with listing: GitHubBranchListing) {
        form.selectedBranch = Self.preselectedBranch(
            current: form.selectedBranch,
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
        form.selectedBranch = nil
        branchSearchTask?.cancel()
        branchSearchText = ""
        completedBranchQuery = nil
        branchSearchResults = []
        // Warm the daemon's repo cache now so the branch step's cached-first
        // paint and the later workspace.create find it fresh (FE parity).
        if let repo = form.selectedRepo {
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
        guard let repo = form.selectedRepo else { return }
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
        guard !query.isEmpty, let repo = form.selectedRepo else {
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
        guard catalogIsVisible, !Task.isCancelled else { return }
        optionsStore.retainCreationOptions(consumer: catalogConsumer)
        let generation = optionsStore.loadGeneration
        async let providerLoad: Void = providerOptions.load()
        await optionsStore.loadIfNeeded(consumer: catalogConsumer)
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
        form.agentSelection.reconcileSpecialist(catalog: optionsStore.specialists)
    }

    /// Defaults the provider selection to a selectable provider (auggie
    /// first) and loads the selected provider's model catalog — instant
    /// when cached, awaited when cold. An explicit model never survives a
    /// provider switch (the daemon default applies), even when the new
    /// provider's catalog shares a bare model id with the old one.
    private func reconcileProviderSelection() async {
        guard catalogIsVisible else { return }
        form.agentSelection.reconcileProvider(state: providerOptions.state)
        optionsStore.selectModelProvider(form.agentSelection.provider?.id, consumer: catalogConsumer)
        guard !providerOptions.isLoading, let provider = form.agentSelection.provider else { return }
        await loadModels(for: provider)
    }

    private func selectProvider(_ provider: ProviderInfo) {
        guard providers.contains(provider), provider.isSelectable, provider.id != form.agentSelection.provider?.id else { return }
        form.agentSelection.selectProvider(provider)
        Task { await loadModels(for: provider) }
    }

    /// Loads the provider's catalog (instant when cached) and settles its
    /// Create gate only when the load returned in the generation it started
    /// in — a completion from before a reconnect clear settles nothing.
    private func loadModels(for provider: ProviderInfo) async {
        guard catalogIsVisible, form.agentSelection.provider?.id == provider.id, !Task.isCancelled else { return }
        optionsStore.selectModelProvider(provider.id, consumer: catalogConsumer)
        let generation = optionsStore.loadGeneration
        await optionsStore.loadModelsIfNeeded(providerId: provider.id, consumer: catalogConsumer)
        settledLoads.settleModels(
            for: provider.id,
            startedAt: generation,
            current: optionsStore.loadGeneration
        )
        if generation == optionsStore.loadGeneration, form.agentSelection.provider?.id == provider.id {
            form.agentSelection.reconcileModels(models)
        }
    }
}

extension CreateWorkspaceView {
    private func createWorkspace() {
        guard !isCreating, !form.images.isImporting, canSubmitProvider,
              let source = repositorySource else { return }
        isCreating = true

        Task { await performCreateWorkspace(source: source) }
    }

    private var repositorySource: WorkspaceRepositorySource? {
        if form.navigationPath.contains(.newRepository) {
            guard let path = form.newRepositoryPath, path == form.newRepositoryDraft.repositoryPath else { return nil }
            return .newRepository(path: path)
        }
        guard let repo = form.selectedRepo, let branch = form.selectedBranch else { return nil }
        return .github(url: "https://github.com/\(repo.owner)/\(repo.name)", baseRef: branch)
    }

    private func performCreateWorkspace(source: WorkspaceRepositorySource) async {
        // Recheck at the request boundary: a refresh may have removed the selection after the tap but before this task ran.
        guard canSubmitProvider, !form.images.isImporting else {
            isCreating = false
            return
        }
        do {
            let idempotencyKey = form.creationAttempts.requestKey(for: source)
            let params = Self.buildCreateWorkspaceParams(
                source: source,
                idempotencyKey: idempotencyKey,
                initialAgent: InitialAgentInput(
                    specialist: form.agentSelection.specialist,
                    provider: form.agentSelection.provider,
                    model: form.agentSelection.model,
                    message: form.messageText,
                    reasoningEffort: validatedReasoningEffort,
                    imageBlocks: form.images.images.map(\.block)
                )
            )
            try WorkspaceCreationImages.validateRequest(params)
            form.creationAttempts.record(idempotencyKey, for: source)
            let result = try await session.connection.request(
                "workspace.create",
                params: params,
                timeout: Self.createRequestTimeout
            )
            if let dictionary = result as? [String: Any],
               let workspaceDictionary = dictionary["workspace"] as? [String: Any],
               let workspace = WorkspaceStore.parseWorkspace(workspaceDictionary) {
                session.workspaceStore.addOrUpdate(workspace)
                form.didCreateWorkspace = true
                session.workspaceCreationDraft = nil
                HapticManager.notification(.success)
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
            selectedProvider: form.agentSelection.provider,
            allowsCreation: coordinator.canCreateWorkspace
        )
    }
}
