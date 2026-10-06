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
    let onSearchTextChanged: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        CreateWorkspaceSelectionPage(
            title: "Select Branch",
            titleIdentifier: "creation.branchTitle",
            searchText: $searchText,
            searchPlaceholder: "Search branches",
            searchIdentifier: "creation.branchSearch",
            searchButtonShowsBackground: false,
            isSearchEnabled: !isLoading && loadError == nil,
            isLoading: isLoading,
            isNextDisabled: selectedBranch == nil,
            onNext: onNext,
            leadingAction: {
                CreateWorkspaceNavigationButton { dismiss() }
            },
            content: {
                content
            }
        )
        .background(CreateWorkspaceRepoStyle.background(for: colorScheme).ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .task { await onLoad() }
        .onChange(of: searchText) { _, newValue in onSearchTextChanged(newValue) }
    }

    @ViewBuilder
    private var content: some View {
        if let loadError {
            VStack(spacing: Constants.CreateWorkspace.errorStateSpacing) {
                Text("Couldn't load branches")
                    .interFont(Constants.Typography.bodyXSEmphasized)
                Text(loadError)
                    .interFont(Constants.Typography.bodyXS)
                    .foregroundStyle(CreateWorkspaceRepoStyle.secondary(for: colorScheme, contrast: contrast))
                Button("Retry", action: onRetry)
                    .buttonStyle(IntentButtonStyle(variant: .secondary))
            }
            .multilineTextAlignment(.center)
            .padding(Constants.CreateWorkspace.errorStatePadding)
            .frame(maxWidth: .infinity)
        } else {
            VStack(alignment: .leading, spacing: CreateWorkspaceRepoStyle.sectionSpacing) {
                sourceSection
                CreateWorkspaceSearchResults { branchList }
            }
        }
    }

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: CreateWorkspaceRepoStyle.sectionHeaderSpacing) {
            sectionHeading("Source")
            ForEach(CreateWorkspaceView.creationContextRows(repositoryFullName: repositoryFullName)) { row in
                contextRow(row)
                    .padding(CreateWorkspaceFormStyle.pagePadding)
                    .frame(maxWidth: .infinity, minHeight: CreateWorkspaceRepoStyle.rowMinimumHeight, alignment: .leading)
                    .background(CreateWorkspaceRepoStyle.card(for: colorScheme), in: .rect(cornerRadius: CreateWorkspaceFormStyle.cornerRadius))
            }
        }
    }

    private var branchList: some View {
        VStack(alignment: .leading, spacing: CreateWorkspaceRepoStyle.sectionHeaderSpacing) {
            sectionHeading("Branches")
            if displayedBranches.isEmpty {
                let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
                Text(query.isEmpty ? "No branches found." : "No branches match \"\(query)\".")
                    .interFont(Constants.Typography.bodyXS)
                    .foregroundStyle(CreateWorkspaceRepoStyle.secondary(for: colorScheme, contrast: contrast))
            }
            LazyVStack(spacing: 0) {
                ForEach(Array(displayedBranches.enumerated()), id: \.element) { index, branch in
                    branchRow(branch)
                        .overlay(alignment: .bottom) {
                            if index + 1 < displayedBranches.count,
                               selectedBranch != branch,
                               selectedBranch != displayedBranches[index + 1] {
                                CreateWorkspaceRepoStyle.divider(for: colorScheme)
                                    .frame(height: CreateWorkspaceRepoStyle.dividerHeight)
                                    .accessibilityHidden(true)
                            }
                        }
                }
            }
        }
    }

    private func sectionHeading(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .interFont(Constants.Typography.eyebrow)
            .textCase(.uppercase)
            .tracking(CreateWorkspaceRepoStyle.sectionTracking)
            .foregroundStyle(CreateWorkspaceRepoStyle.sectionForeground(for: colorScheme, contrast: contrast))
            .accessibilityAddTraits(.isHeader)
    }

    private func branchRow(_ branch: String) -> some View {
        Button {
            selectedBranch = branch
        } label: {
            HStack(spacing: CreateWorkspaceRepoStyle.rowSpacing) {
                Text(branch)
                    .interFont(Constants.Typography.bodySEmphasized)
                    .tracking(CreateWorkspaceRepoStyle.nameTracking)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : Constants.CreateWorkspace.branchNameLineLimit)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .alignmentGuide(VerticalAlignment.center) { dimensions in
                        let additionalLineHeight = dimensions[.lastTextBaseline] - dimensions[.firstTextBaseline]
                        return dimensions[VerticalAlignment.center] - additionalLineHeight / 2
                    }
                HStack(spacing: CreateWorkspaceRepoStyle.rowTextSpacing) {
                    if branch == defaultBranch {
                        defaultBranchBadge
                    }
                    CreateWorkspaceSelectionMark()
                        .opacity(selectedBranch == branch ? 1 : 0)
                }
            }
            .padding(CreateWorkspaceFormStyle.pagePadding)
            .frame(minHeight: CreateWorkspaceRepoStyle.rowMinimumHeight)
            .background(selectedBranch == branch ? CreateWorkspaceRepoStyle.card(for: colorScheme) : .clear, in: .rect(cornerRadius: CreateWorkspaceFormStyle.cornerRadius))
            .contentShape(.rect)
        }
        .buttonStyle(IntentContentButtonStyle())
        .accessibilityAddTraits(selectedBranch == branch ? .isSelected : [])
        .accessibilityIdentifier("creation.branch.\(branch)")
    }

    private var defaultBranchBadge: some View {
        Text("Default")
            .interFont(Constants.Typography.subtextXXS.withFace(.medium))
            .foregroundStyle(CreateWorkspaceRepoStyle.secondary(for: colorScheme, contrast: contrast))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, Constants.WorkspaceRow.outlinedPillHorizontalPadding)
            .padding(.vertical, Constants.WorkspaceRow.pillVerticalPadding)
            .frame(minHeight: Constants.WorkspaceRow.outlinedPillMinimumHeight)
            .overlay {
                Capsule().strokeBorder(
                    contrast == .increased
                        ? Theme.border(for: colorScheme, contrast: contrast)
                        : (colorScheme == .dark ? Color.white : Color.black).opacity(Constants.WorkspaceRow.pillOutlineOpacity),
                    lineWidth: contrast == .increased
                        ? Constants.WorkspaceRow.increasedContrastPillBorderWidth
                        : Constants.WorkspaceRow.pillBorderWidth
                )
            }
    }

    @ViewBuilder
    private func contextRow(_ row: CreateWorkspaceView.CreationContextRow) -> some View {
        if CreateWorkspaceView.usesExpandedFormLayout(for: dynamicTypeSize) {
            VStack(alignment: .leading, spacing: Constants.CreateWorkspace.branchBadgeVerticalPadding) {
                Text(row.label)
                    .interFont(Constants.Typography.bodyXS)
                    .foregroundStyle(CreateWorkspaceRepoStyle.secondary(for: colorScheme, contrast: contrast))
                Text(row.value)
                    .interFont(Constants.Typography.bodyS)
                    .foregroundStyle(CreateWorkspaceRepoStyle.foreground(for: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            LabeledContent {
                Text(row.value)
                    .interFont(Constants.Typography.bodyS)
                    .foregroundStyle(CreateWorkspaceRepoStyle.foreground(for: colorScheme))
                    .multilineTextAlignment(.trailing)
                    .lineLimit(Constants.CreateWorkspace.contextValueLineLimit)
                    .truncationMode(.middle)
            } label: {
                Text(row.label)
                    .interFont(Constants.Typography.bodyS)
                    .foregroundStyle(CreateWorkspaceRepoStyle.foreground(for: colorScheme))
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
