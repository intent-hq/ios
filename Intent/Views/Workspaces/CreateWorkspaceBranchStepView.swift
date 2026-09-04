import SwiftUI

struct CreateWorkspaceBranchStepView: View {
    let displayedBranches: [String]
    let defaultBranch: String?
    let isLoading: Bool
    let loadError: String?
    @Binding var selectedBranch: String?
    @Binding var searchText: String
    let colorScheme: ColorScheme
    let onRetry: () -> Void
    let onNext: () -> Void
    let onLoad: () async -> Void
    let onBranchChanged: () -> Void
    let onSearchTextChanged: (String) -> Void

    var body: some View {
        ZStack {
            Theme.background(for: colorScheme).ignoresSafeArea()

            if isLoading {
                ProgressView("Loading branches...")
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
            } else if let loadError {
                VStack(spacing: Constants.CreateWorkspace.errorStateSpacing) {
                    Text("Couldn't load branches")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.foreground(for: colorScheme))
                    Text(loadError)
                        .font(.subheadline)
                        .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                        .multilineTextAlignment(.center)
                    Button("Retry", action: onRetry)
                }
                .padding(Constants.CreateWorkspace.errorStatePadding)
            } else {
                branchList
            }
        }
        .navigationTitle("Select Branch")
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Next", action: onNext)
                    .disabled(selectedBranch == nil)
            }
        }
        .task { await onLoad() }
        .onChange(of: selectedBranch) { _, _ in onBranchChanged() }
        .onChange(of: searchText) { _, newValue in onSearchTextChanged(newValue) }
    }

    private var branchList: some View {
        List {
            Section("Branches") {
                if displayedBranches.isEmpty {
                    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
                    Text(query.isEmpty ? "No branches found." : "No branches match \"\(query)\".")
                        .font(.subheadline)
                        .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                        .listRowBackground(Theme.card(for: colorScheme))
                }
                ForEach(displayedBranches, id: \.self) { branch in
                    branchRow(branch)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search branches"
        )
    }

    private func branchRow(_ branch: String) -> some View {
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
                        .padding(.horizontal, Constants.CreateWorkspace.branchBadgeHorizontalPadding)
                        .padding(.vertical, Constants.CreateWorkspace.branchBadgeVerticalPadding)
                        .background(Theme.primary(for: colorScheme).opacity(
                            Constants.CreateWorkspace.branchBadgeOpacity))
                        .foregroundStyle(Theme.primary(for: colorScheme))
                        .clipShape(Capsule())
                }
                if selectedBranch == branch {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Theme.primary(for: colorScheme))
                        .fontWeight(.semibold)
                }
            }
            .padding(.vertical, Constants.CreateWorkspace.branchRowVerticalPadding)
        }
        .listRowBackground(Theme.card(for: colorScheme))
    }
}

extension CreateWorkspaceView {
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

    static func orderedBranches(_ branches: [String], defaultBranch: String?) -> [String] {
        guard let defaultBranch, !defaultBranch.isEmpty, !branches.isEmpty else { return branches }
        return [defaultBranch] + branches.filter { $0 != defaultBranch }
    }

    static func preselectedBranch(current: String?, branches: [String], defaultBranch: String?) -> String? {
        if let current, branches.contains(current) { return current }
        return branches.first(where: { $0 == defaultBranch }) ?? branches.first
    }
}