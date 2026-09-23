import SwiftUI

struct CreateWorkspaceBranchStepView: View {
    let repositoryFullName: String
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

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

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
            ToolbarItem(placement: .confirmationAction) {
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
            Section("Source") {
                ForEach(CreateWorkspaceView.creationContextRows(
                    repositoryFullName: repositoryFullName
                )) { row in
                    contextRow(row)
                }
            }
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
            HStack(alignment: .firstTextBaseline) {
                Text(branch)
                    .font(.body)
                    .foregroundStyle(Theme.foreground(for: colorScheme))
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : Constants.CreateWorkspace.branchNameLineLimit)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
                Spacer()
                if branch == defaultBranch {
                    Text("Default")
                        .font(.caption)
                        .padding(.horizontal, Constants.CreateWorkspace.branchBadgeHorizontalPadding)
                        .padding(.vertical, Constants.CreateWorkspace.branchBadgeVerticalPadding)
                        .background(Theme.primary(for: colorScheme).opacity(
                            Constants.CreateWorkspace.branchBadgeOpacity
                        ))
                        .foregroundStyle(Theme.primary(for: colorScheme))
                        .clipShape(Capsule())
                }
                if selectedBranch == branch {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Theme.primary(for: colorScheme))
                        .bold()
                        .accessibilityLabel("Selected")
                }
            }
            .padding(.vertical, Constants.CreateWorkspace.branchRowVerticalPadding)
        }
        .accessibilityAddTraits(selectedBranch == branch ? .isSelected : [])
        .listRowBackground(Theme.card(for: colorScheme))
    }

    @ViewBuilder
    private func contextRow(_ row: CreateWorkspaceView.CreationContextRow) -> some View {
        if CreateWorkspaceView.usesExpandedFormLayout(for: dynamicTypeSize) {
            VStack(alignment: .leading, spacing: Constants.CreateWorkspace.branchBadgeVerticalPadding) {
                Text(row.label)
                    .font(.subheadline)
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                Text(row.value)
                    .foregroundStyle(Theme.foreground(for: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            LabeledContent(row.label) {
                Text(row.value)
                    .foregroundStyle(Theme.foreground(for: colorScheme))
                    .multilineTextAlignment(.trailing)
                    .lineLimit(Constants.CreateWorkspace.contextValueLineLimit)
                    .truncationMode(.middle)
            }
        }
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
        return branches.first { $0 == defaultBranch } ?? branches.first
    }
}
