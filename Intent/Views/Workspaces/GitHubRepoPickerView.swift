import SwiftUI

/// Searchable GitHub repo picker (Create Workspace Step 1): recent repos
/// from the daemon's known-repo registry render immediately on top (no
/// GitHub round-trip), the first page of the user's GitHub repos blends in
/// below, both prefix-filtered client-side by the typed text, followed by
/// deduped debounced global search results. When GitHub is not connected
/// (`github.authStatus.isConfigured == false`) the screen shows
/// desktop-setup guidance for existing repos; the new-repository action
/// remains available. Recents are deliberately auth-gated at render time too: picking a repo needs
/// GitHub for branch listing and workspace creation either way.
///
/// `store` is the session-owned cache: on a reopen the cached lists render
/// immediately (no spinner) while `loadIfNeeded` revalidates silently.
/// Search state stays per-picker (the store is shared by every picker on
/// the session, so one picker's search must not surface in another).
struct GitHubRepoPickerView: View {
    var store: GitHubRepoStore
    @Binding var selectedRepo: GitHubRepo?
    let onCreateRepository: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    @State private var searchText = ""
    @State private var searchResults: [GitHubRepo] = []
    /// The trimmed query the current `searchResults` answer; nil until a
    /// search completes, so stale results never surface.
    @State private var completedSearchQuery: String?
    /// The qualifying query currently in its debounce or remote-search phase.
    @State private var pendingSearchQuery: String?
    @State private var searchTask: Task<Void, Never>?

    private var suggestions: GitHubRepoSuggestions.Sections {
        GitHubRepoSuggestions.merged(
            recentRepos: store.recentRepos,
            ownRepos: store.ownRepos,
            searchResults: searchResults,
            searchQuery: completedSearchQuery,
            currentQuery: searchText
        )
    }

    var body: some View {
        CreateWorkspaceSelectionPage(title: "Select Repository", titleIdentifier: "creation.repositoryTitle") {
            Button(action: onCreateRepository) {
                Label("New Repository", systemImage: "plus")
                    .interFont(Constants.Typography.bodySEmphasized)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(CreateWorkspaceFormStyle.controlPadding)
                    .frame(minHeight: CreateWorkspaceFormStyle.controlHeight)
                    .background(CreateWorkspaceRepoStyle.card(for: colorScheme), in: .rect(
                        cornerRadius: CreateWorkspaceFormStyle.cornerRadius
                    ))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("creation.newRepository")
            content
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if store.hasCheckedAuth, store.isConfigured {
                CreateWorkspaceSearchFooter(text: $searchText)
            }
        }
        .task {
            await store.loadIfNeeded()
        }
        .onChange(of: searchText) { _, newValue in
            scheduleSearch(for: newValue)
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var content: some View {
        if !store.hasCheckedAuth {
            if store.lastError != nil {
                emptyState
            } else {
                ProgressView {
                    Text("Checking GitHub connection...").interFont(Constants.Typography.bodyS)
                }
                .foregroundStyle(CreateWorkspaceRepoStyle.secondary(for: colorScheme, contrast: contrast))
            }
        } else if !store.isConfigured {
            notConnectedPlaceholder
        } else {
            repoList
        }
    }

    private var repoList: some View {
        let sections = suggestions
        return VStack(alignment: .leading, spacing: CreateWorkspaceRepoStyle.sectionHeaderSpacing) {
            if store.isLoading || pendingSearchQuery != nil, sections.isEmpty {
                ProgressView {
                    Text("Loading repositories...").interFont(Constants.Typography.bodyS)
                }
                .foregroundStyle(CreateWorkspaceRepoStyle.secondary(for: colorScheme, contrast: contrast))
            } else if sections.isEmpty {
                emptyState
            } else {
                LazyVStack(alignment: .leading, spacing: CreateWorkspaceRepoStyle.sectionSpacing) {
                    if !sections.recents.isEmpty {
                        GitHubRepoSection(title: "Recent", repos: sections.recents, selectedRepo: $selectedRepo)
                    }
                    if !sections.others.isEmpty {
                        GitHubRepoSection(title: "More", repos: sections.others, selectedRepo: $selectedRepo)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if let lastError = store.lastError {
            ContentUnavailableView {
                Label {
                    Text("Repositories Unavailable").interFont(Constants.Typography.bodyM.withFace(.semibold))
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
            } description: {
                Text(lastError).interFont(Constants.Typography.bodyS)
            }
        } else if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ContentUnavailableView.search
        } else {
            ContentUnavailableView {
                Label {
                    Text("No Repositories").interFont(Constants.Typography.bodyM.withFace(.semibold))
                } icon: {
                    Image(systemName: "folder.badge.questionmark")
                }
            } description: {
                Text("No GitHub repositories are available for your account.").interFont(Constants.Typography.bodyS)
            }
        }
    }

    /// Guidance shown when GitHub is not connected; the GitHub connect flow
    /// runs on the desktop seat and is not available on iOS (same pattern as
    /// the "no providers signed in" placeholder).
    private var notConnectedPlaceholder: some View {
        ContentUnavailableView {
            Label {
                Text("GitHub Is Not Connected").interFont(Constants.Typography.bodyM.withFace(.semibold))
            } icon: {
                Image(systemName: "person.crop.circle.badge.xmark")
            }
        } description: {
            Text("Connect GitHub in the Intent desktop app, then come back and try again.")
                .interFont(Constants.Typography.bodyS)
        }
    }

    // MARK: - Debounced search

    /// Debounce global search ~300ms so rapid keystrokes coalesce into a
    /// single request (FE parity). Queries shorter than the minimum clear
    /// any previous results instead of searching.
    private func scheduleSearch(for text: String) {
        searchTask?.cancel()
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= GitHubRepoSuggestions.minSearchQueryLength else {
            pendingSearchQuery = nil
            completedSearchQuery = nil
            searchResults = []
            return
        }
        pendingSearchQuery = query
        searchTask = Task {
            try? await Task.sleep(for: Constants.GitHubRepoPicker.searchDebounce)
            guard !Task.isCancelled, pendingSearchQuery == query else { return }
            let results = await store.searchRepos(query: query)
            // Publish results + the query they answer together, only if this
            // task is still the latest — an out-of-order older response can't
            // overwrite a newer one's results.
            guard !Task.isCancelled, pendingSearchQuery == query else { return }
            if case let .results(results) = results {
                searchResults = results
                completedSearchQuery = query
            }
            pendingSearchQuery = nil
        }
    }
}

struct CreateWorkspaceSelectionPage<Content: View>: View {
    let title: LocalizedStringKey
    let titleIdentifier: String
    @ViewBuilder let content: Content
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CreateWorkspaceRepoStyle.titleSpacing) {
                Text(title)
                    .interFont(Constants.Typography.heading2)
                    .tracking(CreateWorkspaceRepoStyle.titleTracking)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier(titleIdentifier)
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(CreateWorkspaceFormStyle.pagePadding)
        }
        #if !os(visionOS)
        .scrollDismissesKeyboard(.interactively)
        #endif
        .foregroundStyle(CreateWorkspaceRepoStyle.foreground(for: colorScheme))
        .background(CreateWorkspaceRepoStyle.background(for: colorScheme))
    }
}

struct CreateWorkspaceSearchFooter: View {
    @Binding var text: String
    var placeholder: LocalizedStringKey = "Search GitHub repositories"
    var identifier = "creation.repositorySearch"
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        CreateWorkspaceSelectionSearchField(text: $text, placeholder: placeholder, identifier: identifier)
            .padding(.horizontal, CreateWorkspaceFormStyle.pagePadding)
            .padding(.top, CreateWorkspaceFormStyle.rowSpacing)
            .padding(.bottom, CreateWorkspaceFormStyle.pagePadding)
            .background(CreateWorkspaceRepoStyle.background(for: colorScheme))
    }
}

struct CreateWorkspaceSelectionSearchField: View {
    @Binding var text: String
    var placeholder: LocalizedStringKey = "Search GitHub repositories"
    var identifier = "creation.repositorySearch"
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @ScaledMetric(relativeTo: .body) private var iconSize = CreateWorkspaceRepoStyle.iconSize

    var body: some View {
        HStack(spacing: CreateWorkspaceFormStyle.rowSpacing) {
            TextField(placeholder, text: $text)
                .interFont(Constants.Typography.bodyS)
                .foregroundStyle(CreateWorkspaceRepoStyle.foreground(for: colorScheme))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .accessibilityIdentifier(identifier)
            if text.isEmpty {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: iconSize))
                    .frame(width: iconSize, height: iconSize)
                    .accessibilityHidden(true)
            } else {
                Button {
                    text = ""
                } label: {
                    Image(.close)
                        .resizable()
                        .scaledToFit()
                        .frame(width: iconSize, height: iconSize)
                        .frame(minWidth: CreateWorkspaceFormStyle.controlHeight, minHeight: CreateWorkspaceFormStyle.controlHeight)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .foregroundStyle(CreateWorkspaceRepoStyle.secondary(for: colorScheme, contrast: contrast))
        .padding(.horizontal, CreateWorkspaceFormStyle.controlPadding)
        .frame(minHeight: CreateWorkspaceRepoStyle.searchHeight)
        .background(CreateWorkspaceRepoStyle.card(for: colorScheme), in: .rect(cornerRadius: CreateWorkspaceFormStyle.cornerRadius))
    }
}

private struct GitHubRepoSection: View {
    let title: LocalizedStringKey
    let repos: [GitHubRepo]
    @Binding var selectedRepo: GitHubRepo?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(alignment: .leading, spacing: CreateWorkspaceRepoStyle.sectionHeaderSpacing) {
            Text(title)
                .interFont(Constants.Typography.eyebrow)
                .textCase(.uppercase)
                .tracking(CreateWorkspaceRepoStyle.sectionTracking)
                .foregroundStyle(CreateWorkspaceRepoStyle.sectionForeground(for: colorScheme, contrast: contrast))
                .accessibilityAddTraits(.isHeader)
            LazyVStack(spacing: 0) {
                ForEach(Array(repos.enumerated()), id: \.element.id) { index, repo in
                    GitHubRepoRow(repo: repo, isSelected: selectedRepo?.id == repo.id) {
                        selectedRepo = repo
                    }
                    .overlay(alignment: .bottom) {
                        if index + 1 < repos.count,
                           selectedRepo?.id != repo.id,
                           selectedRepo?.id != repos[index + 1].id {
                            CreateWorkspaceRepoStyle.divider(for: colorScheme)
                                .frame(height: CreateWorkspaceRepoStyle.dividerHeight)
                                .accessibilityHidden(true)
                        }
                    }
                }
            }
        }
    }
}

private struct GitHubRepoRow: View {
    let repo: GitHubRepo
    let isSelected: Bool
    let onSelect: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .body) private var iconSize = CreateWorkspaceRepoStyle.iconSize

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: CreateWorkspaceRepoStyle.rowSpacing) {
                RepoOwnerAvatarView(owner: repo.owner, size: iconSize, cornerRadius: CreateWorkspaceRepoStyle.avatarRadius)
                GitHubRepoLabel(repo: repo)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if isSelected {
                    CreateWorkspaceSelectionMark()
                }
            }
            .padding(CreateWorkspaceFormStyle.pagePadding)
            .frame(minHeight: CreateWorkspaceRepoStyle.rowMinimumHeight)
            .background(isSelected ? CreateWorkspaceRepoStyle.card(for: colorScheme) : .clear, in: .rect(cornerRadius: CreateWorkspaceFormStyle.cornerRadius))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("creation.repository.\(repo.fullName)")
    }
}

struct CreateWorkspaceSelectionMark: View {
    @ScaledMetric(relativeTo: .body) private var iconSize = CreateWorkspaceRepoStyle.iconSize

    var body: some View {
        Image(.checkCircle)
            .resizable()
            .scaledToFit()
            .frame(width: iconSize, height: iconSize)
            .foregroundStyle(.white)
            .clipShape(.rect().inset(by: iconSize * CreateWorkspaceRepoStyle.checkCropRatio))
            .background(SettingsStyle.connected, in: Circle().inset(
                by: iconSize * CreateWorkspaceRepoStyle.checkCircleInsetRatio
            ))
            .accessibilityHidden(true)
    }
}

private struct GitHubRepoLabel: View {
    let repo: GitHubRepo
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var nameCapHeight = CreateWorkspaceRepoStyle.nameCapHeight
    @ScaledMetric(relativeTo: .caption) private var fullNameCapHeight = CreateWorkspaceRepoStyle.fullNameCapHeight

    var body: some View {
        GitHubRepoLabelLayout(capHeights: [nameCapHeight, fullNameCapHeight], spacing: CreateWorkspaceRepoStyle.rowTextSpacing) {
            Text(repo.name)
                .interFont(Constants.Typography.bodySEmphasized)
                .tracking(CreateWorkspaceRepoStyle.nameTracking)
                .foregroundStyle(CreateWorkspaceRepoStyle.foreground(for: colorScheme))
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : Constants.GitHubRepoPicker.repositoryNameLineLimit)
            Text(repo.fullName)
                .interFont(Constants.Typography.subtextXXS)
                .tracking(CreateWorkspaceRepoStyle.fullNameTracking)
                .foregroundStyle(CreateWorkspaceRepoStyle.secondary(for: colorScheme, contrast: contrast))
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                .truncationMode(.middle)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Match Figma's cap-to-baseline text spacing while letting multiline and
/// accessibility text grow naturally. No glyphs are clipped to a fixed height.
private struct GitHubRepoLabelLayout: Layout {
    let capHeights: [CGFloat]
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let textProposal = ProposedViewSize(width: proposal.width, height: nil)
        var size = CGSize.zero
        for (subview, capHeight) in zip(subviews, capHeights) {
            let dimensions = subview.dimensions(in: textProposal)
            size.width = max(size.width, dimensions.width)
            size.height += dimensions[.lastTextBaseline] - dimensions[.firstTextBaseline] + capHeight
        }
        size.height += spacing * CGFloat(max(0, subviews.count - 1))
        return size
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        let textProposal = ProposedViewSize(width: bounds.width, height: nil)
        var capTop = bounds.minY
        for (subview, capHeight) in zip(subviews, capHeights) {
            let dimensions = subview.dimensions(in: textProposal)
            let origin = capTop + capHeight - dimensions[.firstTextBaseline]
            subview.place(at: CGPoint(x: bounds.minX, y: origin), anchor: .topLeading, proposal: textProposal)
            capTop += dimensions[.lastTextBaseline] - dimensions[.firstTextBaseline]
                + capHeight + spacing
        }
    }
}
