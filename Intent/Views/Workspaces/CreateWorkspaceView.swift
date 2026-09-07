import SwiftUI

struct CreateWorkspaceView: View {
    private enum Route: Hashable {
        case branches
        case create
    }

    @Environment(AppCoordinator.self) var coordinator
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) var colorScheme

    /// The presenting window's session; all daemon requests (repo/branch
    /// listing, specialist/provider/model options, workspace.create) go
    /// through its connection so pinned windows never hit the default backend.
    private let session: BackendSession
    @State private var navigationPath: [Route] = []
    @State private var githubStore: GitHubRepoStore
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
    @State private var specialists: [SpecialistInfo] = []
    @State private var isLoadingSpecialists = true
    @State private var selectedSpecialist: SpecialistInfo?
    @State private var providers: [ProviderInfo] = []
    @State private var isLoadingProviders = true
    @State private var selectedProvider: ProviderInfo?
    @State private var models: [ModelInfo] = []
    @State private var selectedModel: ModelInfo?
    @State private var messageText = ""
    @State private var isCreating = false
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var idempotencyKey = UUID().uuidString

    init(session: BackendSession) {
        self.session = session
        _githubStore = State(initialValue: GitHubRepoStore(connectionManager: session.connection))
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            CreateWorkspaceRepoStepView(
                store: githubStore, selectedRepo: $selectedRepo,
                colorScheme: colorScheme,
                onClose: { dismiss() },
                onNext: { navigationPath.append(.branches) },
                onRepoChanged: resetRepositoryState
            )
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .branches:
                        CreateWorkspaceBranchStepView(
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

    private func fetchSpecialists() async {
        isLoadingSpecialists = true
        let agentStore = AgentStore(connectionManager: session.connection)
        var fetched = await agentStore.fetchSpecialists().modalPickable
        let orchestratorId = fetched.orchestrator?.id
        fetched.sort { a, b in
            let aIsOrchestrator = a.id == orchestratorId
            let bIsOrchestrator = b.id == orchestratorId
            if aIsOrchestrator != bIsOrchestrator { return aIsOrchestrator }
            return a.name < b.name
        }
        specialists = fetched
        if selectedSpecialist == nil {
            selectedSpecialist = specialists.orchestrator ?? specialists.first
        }
        isLoadingSpecialists = false
    }

    private func fetchCreationOptions() async {
        async let specialistsTask: () = fetchSpecialists()
        async let providersTask: () = fetchProviders()
        _ = await (specialistsTask, providersTask)
    }

    private func fetchProviders() async {
        isLoadingProviders = true
        defer { isLoadingProviders = false }
        let agentStore = AgentStore(connectionManager: session.connection)
        providers = await agentStore.fetchProviders()
        let selectable = providers.filter { $0.authenticated != false }
        let currentStillSelectable = selectedProvider.map { current in
            selectable.contains(where: { $0.id == current.id })
        } ?? false
        if !currentStillSelectable {
            selectedProvider = selectable.first(where: { $0.id == "auggie" }) ?? selectable.first
        }
        if let provider = selectedProvider {
            await fetchModels(providerId: provider.id)
        } else {
            models = []
            selectedModel = nil
        }
    }

    private func selectProvider(_ provider: ProviderInfo) {
        guard provider.authenticated != false, provider.id != selectedProvider?.id else { return }
        selectedProvider = provider
        selectedModel = nil
        models = []
        Task {
            await fetchModels(providerId: provider.id)
        }
    }

    private func fetchModels(providerId: String) async {
        let agentStore = AgentStore(connectionManager: session.connection)
        let fetched = await agentStore.fetchModels(providerId: providerId)
        guard let outcome = Self.modelFetchOutcome(
            fetched: fetched,
            requestedProviderId: providerId,
            selectedProviderId: selectedProvider?.id
        ) else { return }
        models = outcome.models
        selectedModel = outcome.selectedModel
    }

    static let createRequestTimeout: TimeInterval = 120

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