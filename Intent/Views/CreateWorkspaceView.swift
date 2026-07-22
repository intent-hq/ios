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

    // Step 3: Specialist + Model + Message
    @State private var specialists: [SpecialistInfo] = []
    @State private var isLoadingSpecialists = true
    @State private var selectedSpecialist: SpecialistInfo?
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
                                // Auto-select the specialist's configured model or tier-based default
                                if let specialist = selectedSpecialist {
                                    selectedModel = modelForTier(specialist.modelTier, configuredModel: specialist.model)
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
                .disabled(isCreating)
            }
        }
        .alert("Error", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "An unknown error occurred.")
        }
        .task {
            async let specialistsTask: () = fetchSpecialists()
            async let modelsTask: () = fetchModels()
            _ = await (specialistsTask, modelsTask)
        }
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
        var fetched = await agentStore.fetchSpecialists()
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
        // If models already loaded, update selection based on specialist's configured model or tier
        if !models.isEmpty, let specialist = selectedSpecialist {
            selectedModel = modelForTier(specialist.modelTier, configuredModel: specialist.model)
        }
        isLoadingSpecialists = false
    }

    private func fetchModels() async {
        do {
            let result = try await ConnectionManager.shared.request("agent.getModels")
            if let dict = result as? [String: Any],
               let items = dict["models"] as? [[String: Any]] {
                models = items.compactMap { item in
                    guard let id = item["id"] as? String,
                          let name = item["name"] as? String else { return nil }
                    let provider = item["provider"] as? String ?? "Unknown"
                    return ModelInfo(id: id, name: name, provider: provider)
                }
                // Pre-select model based on selected specialist's configured model or tier, or sonnet4.5 as fallback
                if selectedModel == nil {
                    if let specialist = selectedSpecialist {
                        selectedModel = modelForTier(specialist.modelTier, configuredModel: specialist.model)
                    } else {
                        selectedModel = models.first(where: { $0.id.contains("sonnet4.5") }) ?? models.first
                    }
                }
            }
        } catch {
            print("[CreateWorkspace] Failed to fetch models: \(error)")
        }
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
                    model: selectedModel,
                    message: messageText
                )

                let result = try await ConnectionManager.shared.request("workspace.create", params: params)

                if let dict = result as? [String: Any],
                   let wsDict = dict["workspace"] as? [String: Any],
                   let workspace = WorkspaceStore.parseWorkspace(wsDict) {
                    // Add to workspace store
                    WorkspaceStore.shared.workspaces.insert(workspace, at: 0)
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
        model: ModelInfo?,
        message: String
    ) -> [String: Any] {
        var params: [String: Any] = [
            "repositoryPath": repositoryPath,
            "baseRef": baseRef,
            "idempotencyKey": idempotencyKey
        ]

        // Build initialAgent if specialist or message provided
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasMessage = !trimmedMessage.isEmpty
        if specialist != nil || hasMessage || model != nil {
            var initialAgent: [String: Any] = [:]
            if let specialist = specialist {
                initialAgent["specialist"] = specialist.id
            }
            // Only send model if it differs from the specialist's configured model
            // This lets the daemon's model resolution win when the user hasn't overridden
            if let model = model {
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
    private func modelForTier(_ tier: String?, configuredModel: String? = nil) -> ModelInfo? {
        // First, try the specialist's explicitly configured model
        if let configuredModel = configuredModel,
           let model = models.first(where: { $0.id == configuredModel }) {
            return model
        }

        // Fall back to tier-based mapping
        let modelId: String
        switch tier {
        case "fast": modelId = "haiku4.5"
        case "smart": modelId = "opus4.6"
        default: modelId = "sonnet4.5" // balanced or nil
        }
        return models.first(where: { $0.id == modelId }) ?? models.first
    }
}