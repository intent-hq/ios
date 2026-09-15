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
    @State private var remoteBranches: [String] = []
    @State private var defaultBranch: String?
    @State private var isLoadingBranches = true
    @State private var branchLoadError: String?
    @State private var selectedBranch: String?
    @State private var branchSearchText = ""
    @State private var completedBranchQuery: String?
    @State private var branchSearchResults: [String] = []
    @State private var branchSearchTask: Task<Void, Never>?
    /// True only during a cold specialist/provider load (nothing cached);
    /// a reopen over a warm cache never shows the loading state.
    @State private var isLoadingSpecialists: Bool
    @State private var selectedSpecialist: SpecialistInfo?
    @State private var isLoadingProviders: Bool
    @State private var selectedProvider: ProviderInfo?
    @State private var selectedModel: ModelInfo?
    @State private var messageText = ""
    @State private var isCreating = false
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var idempotencyKey = UUID().uuidString

    init(session: BackendSession) {
        self.session = session
        let cached = session.creationOptionsStore.hasLoaded
        _isLoadingSpecialists = State(initialValue: !cached)
        _isLoadingProviders = State(initialValue: !cached)
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
                            displayedBranches: displayedBranches, defaultBranch: defaultBranch,
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
                            specialists: specialists, isLoadingSpecialists: isLoadingSpecialists,
                            selectedSpecialist: $selectedSpecialist,
                            providers: providers, isLoadingProviders: isLoadingProviders,
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
        .onChange(of: optionsStore.specialists.map(\.id)) { _, _ in
            reconcileSpecialistSelection()
        }
        .onChange(of: optionsStore.providers.map(\.id)) { _, _ in
            Task { await reconcileProviderSelection() }
        }
        .onChange(of: models.map(\.id)) { _, ids in
            if let selectedModel, !ids.contains(selectedModel.id) {
                self.selectedModel = nil
            }
        }
    }

    private var displayedBranches: [String] {
        Self.displayedBranches(
            loaded: remoteBranches, defaultBranch: defaultBranch,
            query: branchSearchText, searchResults: branchSearchResults,
            completedQuery: completedBranchQuery
        )
    }
    private func resetRepositoryState() {
        idempotencyKey = UUID().uuidString
        selectedBranch = nil
        remoteBranches = []
        defaultBranch = nil
        isLoadingBranches = true
        branchSearchTask?.cancel()
        branchSearchText = ""
        completedBranchQuery = nil
        branchSearchResults = []
    }
    private func fetchBranches() async {
        guard let repo = selectedRepo else { return }
        isLoadingBranches = true
        branchLoadError = nil
        do {
            var resolvedDefault = repo.defaultBranch
            if resolvedDefault == nil {
                resolvedDefault = await githubStore.fetchDefaultBranch(owner: repo.owner, repo: repo.name)
            }
            let branches = try await githubStore.fetchRemoteBranches(owner: repo.owner, repo: repo.name)
            defaultBranch = resolvedDefault
            remoteBranches = branches
            selectedBranch = Self.preselectedBranch(
                current: selectedBranch,
                branches: Self.orderedBranches(branches, defaultBranch: resolvedDefault),
                defaultBranch: resolvedDefault
            )
        } catch {
            remoteBranches = []
            branchLoadError = error.localizedDescription
        }
        isLoadingBranches = false
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

    /// Cold (nothing cached): awaits the specialist/provider load and the
    /// selected provider's model catalog with the loading state shown.
    /// Cached: the pickers already render the cached lists — the store
    /// revalidates in the background and the loading state never shows.
    private func fetchCreationOptions() async {
        let cold = !optionsStore.hasLoaded
        if cold {
            isLoadingSpecialists = true
            isLoadingProviders = true
        }
        await optionsStore.loadIfNeeded()
        reconcileSpecialistSelection()
        if cold { isLoadingSpecialists = false }
        await reconcileProviderSelection()
        if cold { isLoadingProviders = false }
    }

    /// Defaults the specialist selection (orchestrator, else first) and
    /// re-defaults it when the selected specialist left the catalog.
    private func reconcileSpecialistSelection() {
        selectedSpecialist = Self.preselectedSpecialist(
            current: selectedSpecialist, specialists: specialists)
    }

    /// Defaults the provider selection to a selectable provider (auggie
    /// first) and loads the selected provider's model catalog — instant
    /// when cached, awaited when cold.
    private func reconcileProviderSelection() async {
        selectedProvider = Self.preselectedProvider(
            current: selectedProvider, providers: providers)
        if let provider = selectedProvider {
            await optionsStore.loadModelsIfNeeded(providerId: provider.id)
        } else {
            selectedModel = nil
        }
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

    /// Keeps `current` while it is still in `specialists`; otherwise the
    /// orchestrator, else the first specialist. An empty list (cold load or
    /// reconnect clear) keeps `current` so the selection survives the reload.
    static func preselectedSpecialist(
        current: SpecialistInfo?, specialists: [SpecialistInfo]
    ) -> SpecialistInfo? {
        guard !specialists.isEmpty else { return current }
        if let current, specialists.contains(where: { $0.id == current.id }) {
            return current
        }
        return specialists.orchestrator ?? specialists.first
    }

    /// Keeps `current` while it is still selectable; otherwise auggie when
    /// selectable, else the first selectable provider, else nil (nothing
    /// selectable — the picker shows setup guidance). An empty list keeps
    /// `current` so the selection survives a reconnect reload.
    static func preselectedProvider(
        current: ProviderInfo?, providers: [ProviderInfo]
    ) -> ProviderInfo? {
        guard !providers.isEmpty else { return current }
        let selectable = providers.filter(\.isSelectable)
        if let current, selectable.contains(where: { $0.id == current.id }) {
            return current
        }
        return selectable.first(where: { $0.id == "auggie" }) ?? selectable.first
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