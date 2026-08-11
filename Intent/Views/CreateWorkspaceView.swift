import SwiftUI

struct CreateWorkspaceView: View {
    @EnvironmentObject var coordinator: AppCoordinator
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) var colorScheme

    // Navigation state
    @State private var navigationPath = NavigationPath()

    // Step 1: GitHub repo selection
    @StateObject private var githubStore = GitHubRepoStore()
    @State private var selectedRepo: GitHubRepo?

    // Step 2: Branch selection
    @State private var remoteBranches: [String] = []
    @State private var defaultBranch: String?
    @State private var isLoadingBranches = true
    @State private var branchLoadError: String?
    @State private var selectedBranch: String?
    @State private var branchSearchText = ""
    /// The trimmed prefix the current `branchSearchResults` answer; nil until
    /// a search completes, so stale results never surface.
    @State private var completedBranchQuery: String?
    @State private var branchSearchResults: [String] = []
    @State private var branchSearchTask: Task<Void, Never>?

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
        GitHubRepoPickerView(store: githubStore, selectedRepo: $selectedRepo)
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
            .onChange(of: selectedRepo?.id) { _, _ in
                // Reset idempotency key and branch state when the repo
                // changes so a branch selected for the previous repo can't
                // carry over (a shared name like "main" would otherwise
                // survive and override the new repo's default).
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
    }

    // MARK: - Step 2: Branch Selection

    private var branchSelectionView: some View {
        ZStack {
            Theme.background(for: colorScheme).ignoresSafeArea()

            if isLoadingBranches {
                ProgressView("Loading branches...")
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
            } else if let branchLoadError {
                VStack(spacing: 12) {
                    Text("Couldn't load branches")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.foreground(for: colorScheme))
                    Text(branchLoadError)
                        .font(.subheadline)
                        .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                        .multilineTextAlignment(.center)
                    Button("Retry") {
                        Task { await fetchBranches() }
                    }
                }
                .padding(24)
            } else {
                List {
                    Section("Branches") {
                        if displayedBranches.isEmpty {
                            let trimmedQuery = branchSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
                            Text(trimmedQuery.isEmpty
                                ? "No branches found."
                                : "No branches match \"\(trimmedQuery)\".")
                                .font(.subheadline)
                                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                                .listRowBackground(Theme.card(for: colorScheme))
                        }
                        ForEach(displayedBranches, id: \.self) { branch in
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
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .searchable(
                    text: $branchSearchText,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Search branches"
                )
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
        .onChange(of: branchSearchText) { _, newValue in
            scheduleBranchSearch(for: newValue)
        }
    }

    /// Branches currently shown in the branch step.
    private var displayedBranches: [String] {
        Self.displayedBranches(
            loaded: remoteBranches,
            defaultBranch: defaultBranch,
            query: branchSearchText,
            searchResults: branchSearchResults,
            completedQuery: completedBranchQuery
        )
    }

    /// No query: the loaded page with the default branch pinned first.
    /// Active query: the latest server prefix-search results (or the pinned
    /// loaded page as an interim while the debounced search is in flight),
    /// narrowed by a local prefix filter — the local filter keeps results
    /// correct even if the daemon ignores `prefix`, and the pinned interim
    /// source keeps an out-of-page default branch matchable.
    static func displayedBranches(
        loaded: [String],
        defaultBranch: String?,
        query: String,
        searchResults: [String],
        completedQuery: String?
    ) -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return orderedBranches(loaded, defaultBranch: defaultBranch)
        }
        let source = completedQuery == trimmed
            ? searchResults
            : orderedBranches(loaded, defaultBranch: defaultBranch)
        return source.filter { $0.hasPrefix(trimmed) }
    }

    /// Pin the default branch to the top of the list (deduped), inserting it
    /// when it falls outside the fetched page so it is always visible. An
    /// empty list stays empty: a successful fetch returning zero branches
    /// means the repo genuinely has none (transport errors take the error
    /// path), so no nonexistent ref is fabricated from repo metadata.
    static func orderedBranches(_ branches: [String], defaultBranch: String?) -> [String] {
        guard let defaultBranch, !defaultBranch.isEmpty, !branches.isEmpty else { return branches }
        return [defaultBranch] + branches.filter { $0 != defaultBranch }
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

                    // Model dropdown picker. The daemon-default row (empty
                    // tag) keeps selectedModel nil; a model is sent only on
                    // an explicit user pick.
                    if !models.isEmpty {
                        Section("Model") {
                            Picker("Model", selection: Binding(
                                get: { selectedModel?.id ?? "" },
                                set: { newId in
                                    selectedModel = models.first(where: { $0.id == newId })
                                }
                            )) {
                                Text(SpecialistInfo.daemonDefaultLabel(
                                    for: selectedSpecialist,
                                    providerId: selectedProvider?.id
                                )).tag("")
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
                    Text("Cloning repository…")
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

    /// Fetch one page of the picked repo's remote branches
    /// (`github.branches.list`), pre-selecting its `defaultBranch` (falling
    /// back to the first branch).
    private func fetchBranches() async {
        guard let repo = selectedRepo else { return }
        isLoadingBranches = true
        branchLoadError = nil
        do {
            // Search results omit `defaultBranch`; resolve it via
            // `github.repos.get` (best-effort) so the default label and
            // pre-selection still work.
            var resolvedDefault = repo.defaultBranch
            if resolvedDefault == nil {
                resolvedDefault = await githubStore.fetchDefaultBranch(owner: repo.owner, repo: repo.name)
            }
            let branches = try await githubStore.fetchRemoteBranches(owner: repo.owner, repo: repo.name)
            defaultBranch = resolvedDefault
            remoteBranches = branches
            // Pre-select against the pinned ordering so the default branch
            // is selectable even when it falls outside the fetched page.
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

    /// Debounce server-side branch prefix search ~300ms so rapid keystrokes
    /// coalesce into a single `github.branches.list` request (same pattern
    /// as the repo picker's `scheduleSearch`). Errors keep the previous
    /// results — the local prefix filter over the loaded page still applies.
    private func scheduleBranchSearch(for text: String) {
        branchSearchTask?.cancel()
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, let repo = selectedRepo else {
            completedBranchQuery = nil
            branchSearchResults = []
            return
        }
        // Already answered (e.g. only surrounding whitespace changed) — skip
        // the redundant round-trip.
        guard query != completedBranchQuery else { return }
        branchSearchTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            guard let results = try? await githubStore.fetchRemoteBranches(
                owner: repo.owner, repo: repo.name, prefix: query
            ) else { return }
            // Publish results + the query they answer together, only if this
            // task is still the latest — an out-of-order older response can't
            // overwrite a newer one's results.
            guard !Task.isCancelled else { return }
            branchSearchResults = results
            completedBranchQuery = query
        }
    }

    /// Keep a still-valid selection (e.g. re-entering the step); otherwise
    /// pre-select the default branch, falling back to the first branch.
    static func preselectedBranch(current: String?, branches: [String], defaultBranch: String?) -> String? {
        if let current, branches.contains(current) { return current }
        return branches.first(where: { $0 == defaultBranch }) ?? branches.first
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
            selectedProviderId: selectedProvider?.id
        ) else { return }
        models = outcome.models
        selectedModel = outcome.selectedModel
    }

    private func createWorkspace() {
        guard !isCreating, let repo = selectedRepo, let branch = selectedBranch else { return }
        isCreating = true

        Task {
            do {
                // githubUrl (no repositoryPath/clonePath) triggers the daemon's
                // cache-hydrated, CoW-preferred clone path (PROTOCOL §5.1).
                // Remote branch names from github.branches.list are plain
                // names, so baseRef needs no remote-prefix normalization.
                let params = Self.buildCreateWorkspaceParams(
                    githubUrl: "https://github.com/\(repo.owner)/\(repo.name)",
                    baseRef: branch,
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

    /// Builds the `workspace.create` params. `githubUrl` without
    /// `repositoryPath`/`clonePath` selects the daemon's cache-hydrated clone
    /// path. Agent IDs are server-assigned, so `initialAgent` must never
    /// contain an `agentId` (the server returns the minted id).
    static func buildCreateWorkspaceParams(
        githubUrl: String,
        baseRef: String,
        idempotencyKey: String,
        specialist: SpecialistInfo?,
        provider: ProviderInfo? = nil,
        model: ModelInfo?,
        message: String
    ) -> [String: Any] {
        var params: [String: Any] = [
            "githubUrl": githubUrl,
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
                initialAgent["provider"] = provider.id
            }
            // model is non-nil only on an explicit user pick — the
            // daemon-default picker row keeps it nil so the daemon's
            // resolver decides
            if let model = model {
                initialAgent["model"] = model.id
            }
            if hasMessage {
                initialAgent["prompt"] = trimmedMessage
            }
            params["initialAgent"] = initialAgent
        }

        return params
    }

    /// Outcome of a completed model fetch, or nil when the fetch is stale
    /// (the selected provider changed while it was in flight) so rapid
    /// provider switching can't apply another provider's catalog/selection.
    /// A fresh catalog always resets the selection to the daemon-default row
    /// (nil) — the daemon's resolver decides unless the user explicitly
    /// picks a model.
    static func modelFetchOutcome(
        fetched: [ModelInfo],
        requestedProviderId: String,
        selectedProviderId: String?
    ) -> (models: [ModelInfo], selectedModel: ModelInfo?)? {
        guard selectedProviderId == requestedProviderId else { return nil }
        return (fetched, nil)
    }
}