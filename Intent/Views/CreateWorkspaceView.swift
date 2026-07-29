import SwiftUI

struct CreateWorkspaceView: View {
    @EnvironmentObject var coordinator: AppCoordinator
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) var colorScheme

    // Navigation state
    @State private var navigationPath = NavigationPath()

    // Step 1: Repo selection
    @State private var repos: [KnownRepo] = []
    @State private var isLoadingRepos = true
    @State private var selectedRepo: KnownRepo?

    // Step 2: Branch selection
    @State private var localBranches: [String] = []
    @State private var remoteBranches: [String] = []
    @State private var currentBranch: String?
    @State private var defaultBranch: String?
    @State private var isLoadingBranches = true
    @State private var selectedBranch: String?

    // Step 3: Specialist + Provider + Model + Message
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

    var body: some View {
        NavigationStack(path: $navigationPath) {
            repoSelectionView
                .navigationDestination(for: String.self) { step in
                    if step == "branches" {
                        branchSelectionView
                    } else if step == "create" {
                        specialistAndMessageView
                    }
                }
        }
    }

    // MARK: - Step 1: Repository Selection

    private var repoSelectionView: some View {
        ZStack {
            Theme.background(for: colorScheme).ignoresSafeArea()

            if isLoadingRepos {
                ProgressView("Loading repositories...")
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
            } else if repos.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "folder.badge.questionmark")
                        .font(.largeTitle)
                        .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                    Text("No repositories found")
                        .font(.headline)
                        .foregroundStyle(Theme.foreground(for: colorScheme))
                    Text("Add a repository in the desktop app first.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                }
            } else {
                List {
                    ForEach(repos) { repo in
                        Button {
                            selectedRepo = repo
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(repo.name)
                                        .font(.headline)
                                        .foregroundStyle(Theme.foreground(for: colorScheme))
                                    Text(repo.path)
                                        .font(.subheadline)
                                        .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                                        .lineLimit(1)
                                }
                                Spacer()
                                if selectedRepo?.id == repo.id {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Theme.primary(for: colorScheme))
                                        .fontWeight(.semibold)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .listRowBackground(Theme.card(for: colorScheme))
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
        }
        .navigationTitle("Select Repository")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .foregroundStyle(Theme.foreground(for: colorScheme))
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Next") {
                    navigationPath.append("branches")
                }
                .disabled(selectedRepo == nil)
            }
        }
        .task {
            await fetchRepos()
        }
        .onChange(of: selectedRepo?.id) { _, _ in
            // Reset idempotency key when repo changes
            idempotencyKey = UUID().uuidString
        }
    }

    // MARK: - Step 2: Branch Selection

    private var branchSelectionView: some View {
        ZStack {
            Theme.background(for: colorScheme).ignoresSafeArea()

            if isLoadingBranches {
                ProgressView("Loading branches...")
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
            } else {
                List {
                    if !localBranches.isEmpty {
                        Section("Local Branches") {
                            ForEach(localBranches, id: \.self) { branch in
                                Button {
                                    selectedBranch = branch
                                } label: {
                                    HStack {
                                        Text(branch)
                                            .font(.body)
                                            .foregroundStyle(Theme.foreground(for: colorScheme))

                                        Spacer()

                                        if branch == defaultBranch {
                                            Text("default")
                                                .font(.caption)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(Theme.primary(for: colorScheme).opacity(0.15))
                                                .foregroundStyle(Theme.primary(for: colorScheme))
                                                .clipShape(Capsule())
                                        }

                                        if branch == currentBranch {
                                            Text("current")
                                                .font(.caption)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(Theme.mutedForeground(for: colorScheme).opacity(0.15))
                                                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                                                .clipShape(Capsule())
                                        }

                                        if selectedBranch == branch {
                                            Image(systemName: "checkmark")
                                                .foregroundStyle(Theme.primary(for: colorScheme))
                                                .fontWeight(.semibold)
                                        }
                                    }
                                    .padding(.vertical, 2)
                                }
                                .listRowBackground(Theme.card(for: colorScheme))
                            }
                        }
                    }

                    if !remoteBranches.isEmpty {
                        Section("Remote Branches") {
                            ForEach(remoteBranches, id: \.self) { branch in
                                Button {
                                    selectedBranch = branch
                                } label: {
                                    HStack {
                                        Text(branch)
                                            .font(.body)
                                            .foregroundStyle(Theme.foreground(for: colorScheme))
                                        Spacer()
                                        if selectedBranch == branch {
                                            Image(systemName: "checkmark")
                                                .foregroundStyle(Theme.primary(for: colorScheme))
                                                .fontWeight(.semibold)
                                        }
                                    }
                                    .padding(.vertical, 2)
                                }
                                .listRowBackground(Theme.card(for: colorScheme))
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
        }
        .navigationTitle("Select Branch")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Next") {
                    navigationPath.append("create")
                }
                .disabled(selectedBranch == nil)
            }
        }
        .task {
            await fetchBranches()
        }
        .onChange(of: selectedBranch) { _, _ in
            // Reset idempotency key when branch changes
            idempotencyKey = UUID().uuidString
        }
    }


    // MARK: - Step 3: Specialist + Model + Message

    private var specialistAndMessageView: some View {
        ZStack {
            Theme.background(for: colorScheme).ignoresSafeArea()

            if isLoadingSpecialists {
                ProgressView("Loading...")
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
            } else {
                List {
                    // Message section
                    Section("Initial Message") {
                        TextField("Describe what you'd like to do...", text: $messageText, axis: .vertical)
                            .lineLimit(3...6)
                            .font(.body)
                            .foregroundStyle(Theme.foreground(for: colorScheme))
                            .listRowBackground(Theme.card(for: colorScheme))
                    }

                    // Specialist dropdown picker
                    Section("Specialist") {
                        Picker("Specialist", selection: Binding(
                            get: { selectedSpecialist?.id ?? "" },
                            set: { newId in
                                selectedSpecialist = specialists.first(where: { $0.id == newId })
                                // Auto-select the specialist's configured model or tier-based default (auggie only)
                                if let specialist = selectedSpecialist, isAuggieSelected {
                                    selectedModel = Self.modelForTier(specialist.modelTier, configuredModel: specialist.model, in: models)
                                }
                            }
                        )) {
                            ForEach(specialists) { specialist in
                                Text(specialist.name).tag(specialist.id)
                            }
                        }
                        .pickerStyle(.menu)
                        .listRowBackground(Theme.card(for: colorScheme))
                    }

                    // Provider dropdown picker. When providers exist but none
                    // are signed in, show desktop-setup guidance instead of a
                    // menu with no valid selection (monorepo#985); the Model
                    // section stays hidden since no catalog is fetched.
                    if providers.noneSelectable {
                        Section("Provider") {
                            noProvidersSignedInPlaceholder
                                .listRowBackground(Theme.card(for: colorScheme))
                        }
                    } else if !providers.isEmpty {
                        Section("Provider") {
                            Picker("Provider", selection: Binding(
                                get: { selectedProvider?.id ?? "" },
                                set: { newId in
                                    // selectProvider guards unauthenticated providers and
                                    // handles the model refetch/reset side effects
                                    if let provider = providers.first(where: { $0.id == newId }) {
                                        selectProvider(provider)
                                    }
                                }
                            )) {
                                ForEach(providers) { provider in
                                    Text(provider.authenticated == false
                                        ? "\(provider.displayName) (not signed in)"
                                        : provider.displayName)
                                        .tag(provider.id)
                                }
                            }
                            .pickerStyle(.menu)
                            .listRowBackground(Theme.card(for: colorScheme))
                        }
                    }

                    // Model dropdown picker
                    if !models.isEmpty {
                        Section("Model") {
                            Picker("Model", selection: Binding(
                                get: { selectedModel?.id ?? "" },
                                set: { newId in
                                    selectedModel = models.first(where: { $0.id == newId })
                                }
                            )) {
                                ForEach(models) { model in
                                    Text(model.name).tag(model.id)
                                }
                            }
                            .pickerStyle(.menu)
                            .listRowBackground(Theme.card(for: colorScheme))
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }

            // Creating overlay
            if isCreating {
                Color.black.opacity(0.3).ignoresSafeArea()
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Creating workspace...")
                        .font(.subheadline)
                        .foregroundStyle(Theme.foreground(for: colorScheme))
                }
                .padding(24)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
        .navigationTitle("Create Workspace")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(isCreating)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Create") {
                    createWorkspace()
                }
                .disabled(Self.isCreateDisabled(
                    isCreating: isCreating,
                    isLoadingProviders: isLoadingProviders,
                    providers: providers
                ))
            }
        }
        .alert("Error", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "An unknown error occurred.")
        }
        .task {
            async let specialistsTask: () = fetchSpecialists()
            async let providersTask: () = fetchProviders()
            _ = await (specialistsTask, providersTask)
        }
    }

    /// Whether the effective provider is auggie (no explicit selection defaults to auggie).
    private var isAuggieSelected: Bool {
        (selectedProvider?.id ?? "auggie") == "auggie"
    }

    /// Guidance shown when providers exist but none are signed in; provider
    /// sign-in flows run on the desktop seat and are not available on iOS.
    private var noProvidersSignedInPlaceholder: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("No providers are signed in")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.foreground(for: colorScheme))
            Text("Set up a provider in the Intent desktop app, then come back and try again.")
                .font(.subheadline)
                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
        }
        .padding(.vertical, 4)
    }

    /// The Create action is unavailable while a create is in flight, the
    /// provider list is still loading (an empty in-flight list can't be told
    /// apart from a seat with no providers), or no provider is selectable —
    /// the desktop-setup guidance state, where submission would only fail
    /// daemon-side (monorepo#1003).
    static func isCreateDisabled(isCreating: Bool, isLoadingProviders: Bool, providers: [ProviderInfo]) -> Bool {
        isCreating || isLoadingProviders || providers.noneSelectable
    }

    // MARK: - Data Fetching

    private func fetchRepos() async {
        isLoadingRepos = true
        do {
            let result = try await ConnectionManager.shared.request("repo.list")
            if let dict = result as? [String: Any],
               let items = dict["repos"] as? [[String: Any]] {
                repos = items.compactMap { item in
                    guard let path = item["path"] as? String,
                          let name = item["name"] as? String else { return nil }
                    return KnownRepo(
                        path: path,
                        name: name,
                        owner: item["owner"] as? String,
                        addedAt: item["addedAt"] as? String,
                        lastUsedAt: item["lastUsedAt"] as? String
                    )
                }
            }
        } catch {
            print("[CreateWorkspace] Failed to fetch repos: \(error)")
        }
        isLoadingRepos = false
    }

    private func fetchBranches() async {
        guard let repo = selectedRepo else { return }
        isLoadingBranches = true
        do {
            let result = try await ConnectionManager.shared.request(
                "git.getBranches",
                params: ["repoPath": repo.path, "includeRemote": true]
            )
            if let dict = result as? [String: Any] {
                if let branches = dict["branches"] as? [String] {
                    localBranches = branches
                }
                if let remote = dict["remoteBranches"] as? [String] {
                    remoteBranches = remote
                }
                currentBranch = dict["currentBranch"] as? String
                defaultBranch = dict["defaultBranch"] as? String

                // Auto-select default branch, or current branch, or first local branch
                if selectedBranch == nil {
                    selectedBranch = defaultBranch ?? currentBranch ?? localBranches.first
                }
            }
        } catch {
            print("[CreateWorkspace] Failed to fetch branches: \(error)")
        }
        isLoadingBranches = false
    }

    private func fetchSpecialists() async {
        isLoadingSpecialists = true
        let agentStore = AgentStore()
        var fetched = await agentStore.fetchSpecialists().pickable
        // Sort so Coordinator (spec-writer) is first
        fetched.sort { a, b in
            let aIsCoordinator = a.id == "spec-writer"
            let bIsCoordinator = b.id == "spec-writer"
            if aIsCoordinator != bIsCoordinator { return aIsCoordinator }
            return a.name < b.name
        }
        specialists = fetched
        // Default to Coordinator specialist
        if selectedSpecialist == nil {
            selectedSpecialist = specialists.first(where: {
                $0.id == "spec-writer" || $0.name.lowercased().contains("coordinator")
            }) ?? specialists.first
        }
        // If models already loaded, update selection based on specialist's configured model or tier (auggie only)
        if !models.isEmpty, isAuggieSelected, let specialist = selectedSpecialist {
            selectedModel = Self.modelForTier(specialist.modelTier, configuredModel: specialist.model, in: models)
        }
        isLoadingSpecialists = false
    }

    private func fetchProviders() async {
        isLoadingProviders = true
        defer { isLoadingProviders = false }
        let agentStore = AgentStore()
        providers = await agentStore.fetchProviders()
        let selectable = providers.filter { $0.authenticated != false }
        // Default: auggie if selectable, else first selectable. Also fall back if the
        // current selection became disabled.
        let currentStillSelectable = selectedProvider.map { current in
            selectable.contains(where: { $0.id == current.id })
        } ?? false
        if !currentStillSelectable {
            selectedProvider = selectable.first(where: { $0.id == "auggie" }) ?? selectable.first
        }
        if let provider = selectedProvider {
            await fetchModels(providerId: provider.id)
        } else {
            // No selectable provider: drop any stale catalog/selection so the
            // Model section can't render (or ship a model) next to the
            // desktop-setup guidance.
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
        let agentStore = AgentStore()
        let fetched = await agentStore.fetchModels(providerId: providerId)
        // Drop stale results if the provider changed while fetching
        guard let outcome = Self.modelFetchOutcome(
            fetched: fetched,
            requestedProviderId: providerId,
            selectedProviderId: selectedProvider?.id,
            specialist: selectedSpecialist
        ) else { return }
        models = outcome.models
        selectedModel = outcome.selectedModel
    }

    private func createWorkspace() {
        guard !isCreating, let repo = selectedRepo, let branch = selectedBranch else { return }
        isCreating = true

        Task {
            do {
                // Normalize branch name: strip "origin/" or other known remote prefixes
                let normalizedBranch = normalizeBranchName(branch)

                let params = Self.buildCreateWorkspaceParams(
                    repositoryPath: repo.path,
                    baseRef: normalizedBranch,
                    idempotencyKey: idempotencyKey,
                    specialist: selectedSpecialist,
                    provider: selectedProvider,
                    model: selectedModel,
                    message: messageText
                )

                let result = try await ConnectionManager.shared.request("workspace.create", params: params)

                if let dict = result as? [String: Any],
                   let wsDict = dict["workspace"] as? [String: Any],
                   let workspace = WorkspaceStore.parseWorkspace(wsDict) {
                    // Upsert into the workspace store — the live subscription delta
                    // may have already added this workspace (#1066)
                    WorkspaceStore.shared.addOrUpdate(workspace)
                    HapticManager.notification(.success)
                    // Reset idempotency key on success
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

    /// Builds the `workspace.create` params. Agent IDs are server-assigned, so
    /// `initialAgent` must never contain an `agentId` (the server returns the minted id).
    static func buildCreateWorkspaceParams(
        repositoryPath: String,
        baseRef: String,
        idempotencyKey: String,
        specialist: SpecialistInfo?,
        provider: ProviderInfo? = nil,
        model: ModelInfo?,
        message: String
    ) -> [String: Any] {
        var params: [String: Any] = [
            "repositoryPath": repositoryPath,
            "baseRef": baseRef,
            "idempotencyKey": idempotencyKey
        ]

        // A nil provider means the auggie default (provider omitted on the wire)
        let isNonAuggieProvider = provider.map { $0.id != "auggie" } ?? false

        // Build initialAgent if specialist, message, model, or non-default provider provided
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasMessage = !trimmedMessage.isEmpty
        if specialist != nil || hasMessage || model != nil || isNonAuggieProvider {
            var initialAgent: [String: Any] = [:]
            if let specialist = specialist {
                initialAgent["specialist"] = specialist.id
            }
            if isNonAuggieProvider, let provider = provider {
                // Non-auggie provider: always send provider, plus the bare model id when selected
                initialAgent["provider"] = provider.id
                if let model = model {
                    initialAgent["model"] = model.id
                }
            } else if let model = model {
                // Auggie (or no provider selected): only send model if it differs from the
                // specialist's configured model, so the daemon's model resolution wins when
                // the user hasn't overridden
                if let specialist = specialist {
                    // If specialist has a configured model, only send if different
                    if let configuredModel = specialist.model {
                        if configuredModel != model.id {
                            initialAgent["model"] = model.id
                        }
                    } else {
                        // Specialist has no configured model; omit model to let daemon resolve
                        // (the tier-based default we're showing is just UI guidance)
                    }
                } else {
                    // No specialist, send the model
                    initialAgent["model"] = model.id
                }
            }
            if hasMessage {
                initialAgent["prompt"] = trimmedMessage
            }
            params["initialAgent"] = initialAgent
        }

        return params
    }

    /// Normalize a branch name by stripping known remote prefixes (e.g., "origin/main" -> "main")
    private func normalizeBranchName(_ branch: String) -> String {
        let knownRemotes = ["origin/", "upstream/", "fork/"]
        for remote in knownRemotes {
            if branch.hasPrefix(remote) {
                return String(branch.dropFirst(remote.count))
            }
        }
        return branch
    }

    /// Returns the model matching a specialist's configured model or tier, falling back to sonnet4.5 or the first available model.
    private static func modelForTier(_ tier: String?, configuredModel: String? = nil, in models: [ModelInfo]) -> ModelInfo? {
        // First, try the specialist's explicitly configured model
        if let configuredModel = configuredModel,
           let model = models.first(where: { $0.id == configuredModel }) {
            return model
        }

        // Fall back to the shared tier-based mapping
        let modelId = SpecialistInfo.modelId(forTier: tier)
        return models.first(where: { $0.id == modelId }) ?? models.first
    }

    /// Outcome of a completed model fetch, or nil when the fetch is stale
    /// (the selected provider changed while it was in flight) so rapid
    /// provider switching can't apply another provider's catalog/selection.
    static func modelFetchOutcome(
        fetched: [ModelInfo],
        requestedProviderId: String,
        selectedProviderId: String?,
        specialist: SpecialistInfo?
    ) -> (models: [ModelInfo], selectedModel: ModelInfo?)? {
        guard selectedProviderId == requestedProviderId else { return nil }
        // Reset selection: specialist-driven preselection for auggie, provider default otherwise
        let selection: ModelInfo?
        if requestedProviderId == "auggie", let specialist = specialist {
            selection = modelForTier(specialist.modelTier, configuredModel: specialist.model, in: fetched)
        } else {
            selection = fetched.first(where: { $0.isDefault }) ?? fetched.first
        }
        return (fetched, selection)
    }
}