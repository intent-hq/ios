import SwiftUI

/// A pull request's detail in the workspace page's language: a large title
/// with one quiet subtitle, the shared content switcher, and plain rows for
/// the linked workspace, checks and reviews above the description. Code lists
/// the changed files with their diffs.
struct PullRequestDetailView: View {
    nonisolated enum Tab: String, CaseIterable {
        case code = "Code"
        case summary = "Summary"

        static let allCases: [Self] = [.summary, .code]
    }

    @State private var store: PullRequestDetailStore
    let linkedWorkspace: Workspace?
    /// A sheet (the iPad sidebar) closes instead of going back.
    var isModal = false
    let onOpenWorkspace: (String) -> Void
    @State private var tab: Tab = .summary
    @State private var showsChecks = false
    @State private var showsReviews = false
    @State private var expandedFiles: Set<String> = []
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 20
    @ScaledMetric(relativeTo: .body) private var avatarSize: CGFloat = 20
    @ScaledMetric(relativeTo: .title) private var titleTracking = WorkspaceDetailStyle.titleTracking

    init(
        item: PullRequestListItem,
        connection: any ConnectionManagerRouting,
        linkedWorkspace: Workspace?,
        isModal: Bool = false,
        onOpenWorkspace: @escaping (String) -> Void
    ) {
        _store = State(initialValue: PullRequestDetailStore(item: item, connection: connection))
        self.linkedWorkspace = linkedWorkspace
        self.isModal = isModal
        self.onOpenWorkspace = onOpenWorkspace
    }

    var item: PullRequestListItem { store.item }
    var secondary: Color { WorkspaceDetailStyle.secondary(for: colorScheme, contrast: contrast) }
    var foreground: Color { WorkspaceDetailStyle.foreground(for: colorScheme) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                heading
                IntentContentSwitcher(
                    selection: $tab,
                    options: Tab.allCases.map { IntentContentSwitcher<Tab>.Option(value: $0, title: $0.rawValue) },
                    accessibilityLabel: "Pull request content",
                    identifierPrefix: "pullRequest.tab"
                )
                .padding(.bottom, WorkspaceDetailStyle.sectionHeadingSpacing)
                switch tab {
                case .summary: summary
                case .code: code
                }
            }
            .padding(.horizontal, WorkspaceDetailStyle.pageInset)
            .padding(.bottom, WorkspaceDetailStyle.pageInset)
        }
        .background(WorkspaceDetailStyle.background(for: colorScheme))
        .safeAreaInset(edge: .top, spacing: 0) {
            // The workspace page's header: back (or close in a sheet), title, overflow menu.
            WorkspaceNavigationHeader(
                title: item.title,
                subtitle: "Pull request",
                backLabel: isModal ? "Close" : "Back to pull requests",
                backIdentifier: "pullRequest.back",
                leadingIcon: isModal ? .close : .arrowLeft,
                onBack: { dismiss() }
            ) { overflowMenu }
        }
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden()
        .nativeNavigationBackGesture()
        .accessibilityAction(.escape) { dismiss() }
        .task { await store.loadAll() }
        .accessibilityIdentifier("pullRequest.detail")
    }
}

// MARK: - Heading

private extension PullRequestDetailView {
    var heading: some View {
        VStack(alignment: .leading, spacing: WorkspaceDetailStyle.headingSpacing) {
            Text(item.title)
                .interFont(Constants.Typography.heading2)
                .tracking(titleTracking)
                .foregroundStyle(foreground)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: Style.subtitleSpacing) {
                Image(WorkspaceRowView.pillImage(for: item.status))
                    .resizable().scaledToFit()
                    .frame(width: Style.subtitleIconSize, height: Style.subtitleIconSize)
                    .foregroundStyle(PullRequestRowView.stateColor(item.status, colorScheme: colorScheme, contrast: contrast))
                    .accessibilityHidden(true)
                Text("\(item.owner)/\(item.repo) · #\(item.number)")
                    .interFont(Constants.Typography.subtextXXS)
                    .foregroundStyle(secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(item.status.rawValue.capitalized) pull request #\(item.number) in \(item.owner)/\(item.repo)")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, Style.headingTopSpacing)
        .padding(.bottom, WorkspaceDetailStyle.headingBottomSpacing)
    }

    var overflowMenu: some View {
        Menu {
            if let url = item.url {
                Button("Open on GitHub", systemImage: "safari") { openURL(url) }
                    .accessibilityIdentifier("pullRequest.openOnGitHub")
                ShareLink(item: url)
            }
            if let linkedWorkspace {
                Button("Open workspace", systemImage: "folder") { onOpenWorkspace(linkedWorkspace.id) }
            }
        } label: {
            ToolbarOverflowLabel()
        }
        .buttonStyle(IntentContentButtonStyle())
        .accessibilityLabel("Pull request options")
        .accessibilityIdentifier("pullRequest.menu")
    }
}

// MARK: - Summary

private extension PullRequestDetailView {
    var summary: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let linkedWorkspace {
                row(icon: .folders, title: linkedWorkspace.title, accessory: .chevron) {
                    onOpenWorkspace(linkedWorkspace.id)
                }
                .accessibilityLabel("Open workspace \(linkedWorkspace.title)")
                .accessibilityIdentifier("pullRequest.workspace")
            }
            checksRow
            if showsChecks { checkList }
            reviewsRow
            if showsReviews { reviewerList }
            description
                .padding(.top, WorkspaceDetailStyle.sectionHeadingSpacing)
        }
    }

    @ViewBuilder var checksRow: some View {
        if let error = store.errors[.checks] {
            failure("Checks", error) { Task { await store.load(.checks) } }
        } else if let summary = PullRequestCheck.summary(store.checks) {
            let appearance = checkAppearance(summary.state)
            row(icon: appearance.icon, title: summary.label, accessory: .disclosure(showsChecks), tint: appearance.color) {
                withAnimation(.snappy) { showsChecks.toggle() }
            }
            .accessibilityIdentifier("pullRequest.checks")
        } else {
            row(icon: .infoCircle, title: store.loading.contains(.checks) ? "Loading checks…" : "No checks", accessory: .none) {}
                .disabled(true)
        }
    }

    var checkList: some View {
        ForEach(store.checks) { check in
            let appearance = checkAppearance(check.state)
            row(
                icon: appearance.icon,
                title: check.name,
                accessory: check.url == nil ? .none : .external,
                tint: appearance.color,
                indented: true
            ) {
                if let url = check.url { openURL(url) }
            }
        }
    }

    @ViewBuilder var reviewsRow: some View {
        if let error = store.errors[.reviews] {
            failure("Reviews", error) { Task { await store.load(.reviews) } }
        } else if store.reviewers.isEmpty {
            row(icon: .messageCheck, title: store.loading.contains(.reviews) ? "Loading reviews…" : "No reviews yet", accessory: .none) {}
                .disabled(true)
        } else {
            row(icon: .messageCheck, title: reviewSummary, accessory: .disclosure(showsReviews)) {
                withAnimation(.snappy) { showsReviews.toggle() }
            }
            .accessibilityIdentifier("pullRequest.reviews")
        }
    }

    /// "Approved by mona", "2 reviewers": the one verdict that matters first.
    var reviewSummary: String {
        let reviewers = store.reviewers
        if reviewers.count == 1, let only = reviewers.first {
            return only.state == "requested" ? "Review requested from \(only.login)" : "\(only.verdict) by \(only.login)"
        }
        return "\(reviewers.count) reviewers"
    }

    var reviewerList: some View {
        ForEach(store.reviewers) { reviewer in
            HStack(spacing: Style.rowIconSpacing) {
                RepoOwnerAvatarView(owner: reviewer.login, size: avatarSize, fallbackSymbol: "person.fill", cornerRadius: avatarSize / 2)
                    .accessibilityHidden(true)
                Text(reviewer.login)
                    .interFont(Constants.Typography.bodyS)
                    .foregroundStyle(foreground)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(reviewer.verdict)
                    .interFont(Constants.Typography.subtextXXS)
                    .foregroundStyle(secondary)
            }
            .padding(.leading, iconSize + Style.rowIconSpacing)
            .padding(.vertical, Style.childRowPadding)
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder var description: some View {
        if let detail = store.detail {
            if detail.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                muted("No description")
            } else {
                MarkdownTextView(text: detail.body)
            }
        } else if let error = store.errors[.detail] {
            failure("Description", error) { Task { await store.load(.detail) } }
        } else {
            ProgressView().frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    func checkAppearance(_ state: PullRequestCheck.State) -> (icon: ImageResource, color: Color) {
        switch state {
        case .success: (.checkCircle, Constants.Colors.WorkspaceStatus.prOpen)
        case .failure, .cancelled: (.closeCircle, Theme.destructive(for: colorScheme))
        case .pending: (.historyCircle3, secondary)
        case .neutral: (.infoCircle, secondary)
        }
    }
}

// MARK: - Rows

private extension PullRequestDetailView {
    enum Accessory: Equatable {
        case chevron
        case disclosure(Bool)
        case external
        case none
    }

    /// The one row shape for the summary: icon, body-sized title, trailing cue.
    func row(
        icon: ImageResource,
        title: String,
        accessory: Accessory,
        tint: Color? = nil,
        indented: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: Style.rowIconSpacing) {
                Image(icon).resizable().scaledToFit()
                    .frame(width: iconSize, height: iconSize)
                    .foregroundStyle(tint ?? secondary)
                    .accessibilityHidden(true)
                Text(title)
                    .interFont(indented ? Constants.Typography.bodyXS : Constants.Typography.bodyS)
                    .foregroundStyle(foreground)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                accessoryView(accessory)
            }
            .padding(.leading, indented ? iconSize + Style.rowIconSpacing : 0)
            .padding(.vertical, indented ? Style.childRowPadding : Style.rowPadding)
            .contentShape(.rect)
        }
        .buttonStyle(IntentContentButtonStyle())
        .accessibilityValue(accessory == .disclosure(true) ? "Expanded" : accessory == .disclosure(false) ? "Collapsed" : "")
    }

    @ViewBuilder func accessoryView(_ accessory: Accessory) -> some View {
        switch accessory {
        case .chevron, .disclosure:
            Image(.chevronRight).resizable().scaledToFit()
                .frame(width: Style.accessorySize, height: Style.accessorySize)
                .rotationEffect(.degrees(accessory == .disclosure(true) ? Style.expandedRotation : 0))
                .foregroundStyle(secondary)
                .accessibilityHidden(true)
        case .external:
            Image(.external).resizable().scaledToFit()
                .frame(width: Style.accessorySize, height: Style.accessorySize)
                .foregroundStyle(secondary)
                .accessibilityHidden(true)
        case .none:
            EmptyView()
        }
    }
}

// MARK: - Code

private extension PullRequestDetailView {
    @ViewBuilder var code: some View {
        if let head = store.detail?.headRef ?? item.headRef {
            HStack(spacing: Style.subtitleSpacing) {
                Image(.gitBranch).resizable().scaledToFit()
                    .frame(width: Style.subtitleIconSize, height: Style.subtitleIconSize)
                    .accessibilityHidden(true)
                Text(store.detail?.baseRef.map { "\(head) → \($0)" } ?? head)
                    .interFont(Constants.Typography.subtextXXS)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .foregroundStyle(secondary)
            .padding(.bottom, Style.rowPadding)
        }
        if store.loading.contains(.files), store.files.isEmpty {
            ProgressView().frame(maxWidth: .infinity, alignment: .leading)
        } else if let error = store.errors[.files] {
            failure("Files", error) { Task { await store.load(.files) } }
        } else if store.files.isEmpty {
            muted("No changed files")
        } else {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(store.files) { file in
                    fileRow(file)
                    Divider()
                }
                if store.filesTruncated {
                    muted("Showing the first \(PullRequestDetailStore.filesLimit) files. Open on GitHub for the rest.")
                        .padding(.top, Style.rowPadding)
                }
            }
        }
    }

    func fileRow(_ file: PullRequestFile) -> some View {
        let expanded = expandedFiles.contains(file.id)
        return VStack(alignment: .leading, spacing: 0) {
            fileHeader(file, expanded: expanded)
            if expanded {
                WorkspaceFileDiffView(
                    loader: nil,
                    path: file.filename,
                    isBinary: file.patch == nil,
                    embedded: true,
                    patch: file.patch
                )
                .clipShape(.rect(cornerRadius: Style.diffCornerRadius))
                .padding(.bottom, Style.fileRowPadding)
            }
        }
    }

    func fileHeader(_ file: PullRequestFile, expanded: Bool) -> some View {
        Button {
            withAnimation(.snappy) {
                if expanded { expandedFiles.remove(file.id) } else { expandedFiles.insert(file.id) }
            }
        } label: {
            HStack(spacing: Style.rowIconSpacing) {
                Text(file.filename)
                    .font(.footnote.monospaced())
                    .foregroundStyle(foreground)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
                WorkspaceChangeStats(additions: file.additions, deletions: file.deletions)
                Image(.chevronRight).resizable().scaledToFit()
                    .frame(width: Style.accessorySize, height: Style.accessorySize)
                    .rotationEffect(.degrees(expanded ? Style.expandedRotation : 0))
                    .foregroundStyle(secondary)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, Style.fileRowPadding)
            .contentShape(.rect)
        }
        .buttonStyle(IntentContentButtonStyle())
        .accessibilityValue(expanded ? "Expanded" : "Collapsed")
        .accessibilityIdentifier("pullRequest.file.\(file.filename)")
    }
}

// MARK: - Shared

private extension PullRequestDetailView {
    func muted(_ text: String) -> some View {
        Text(text)
            .interFont(Constants.Typography.bodyXS)
            .foregroundStyle(secondary)
    }

    func failure(_ title: String, _ message: String, retry: @escaping () -> Void) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Style.rowIconSpacing) {
            VStack(alignment: .leading, spacing: Style.childRowPadding) {
                Text(title)
                    .interFont(Constants.Typography.bodyS)
                    .foregroundStyle(foreground)
                muted(message)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Retry", action: retry)
                .buttonStyle(IntentButtonStyle(variant: .muted))
        }
        .padding(.vertical, Style.rowPadding)
    }
}

private enum Style {
    static let headingTopSpacing: CGFloat = 16
    static let subtitleSpacing: CGFloat = 6
    static let subtitleIconSize: CGFloat = 14
    static let rowIconSpacing: CGFloat = 14
    static let rowPadding: CGFloat = 14
    static let childRowPadding: CGFloat = 8
    static let accessorySize: CGFloat = 16
    static let fileRowPadding: CGFloat = 14
    static let diffCornerRadius: CGFloat = 12
    static let expandedRotation: Double = 90
}
