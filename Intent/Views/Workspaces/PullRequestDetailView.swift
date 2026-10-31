import SwiftUI

/// A pull request's detail, matching the FE Home detail panel: title with
/// state and number, author, repository and branches, then Summary
/// (reviewers, checks, description) and Code (changed files with diffs).
struct PullRequestDetailView: View {
    nonisolated enum Tab: String, CaseIterable {
        case code = "Code"
        case summary = "Summary"

        static let allCases: [Self] = [.summary, .code]
    }

    @State private var store: PullRequestDetailStore
    let linkedWorkspace: Workspace?
    let onOpenWorkspace: (String) -> Void
    @State private var tab: Tab = .summary
    @State private var showsChecks = false
    @State private var expandedFiles: Set<String> = []
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @ScaledMetric(relativeTo: .body) private var avatarSize: CGFloat = 22
    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 16

    init(
        item: PullRequestListItem,
        connection: any ConnectionManagerRouting,
        linkedWorkspace: Workspace?,
        onOpenWorkspace: @escaping (String) -> Void
    ) {
        _store = State(initialValue: PullRequestDetailStore(item: item, connection: connection))
        self.linkedWorkspace = linkedWorkspace
        self.onOpenWorkspace = onOpenWorkspace
    }

    private var item: PullRequestListItem { store.item }
    private var secondary: Color { Constants.WorkspaceList.secondaryText(for: colorScheme, contrast: contrast) }
    private var foreground: Color { Theme.foreground(for: colorScheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            tabBar
            Divider()
            ScrollView {
                Group {
                    switch tab {
                    case .summary: summary
                    case .code: code
                    }
                }
                .padding(Style.inset)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(WorkspaceDetailStyle.background(for: colorScheme))
        .task { await store.loadAll() }
        .accessibilityIdentifier("pullRequest.detail")
    }
}

// MARK: - Header

private extension PullRequestDetailView {
    var header: some View {
        VStack(alignment: .leading, spacing: Style.metaSpacing) {
            HStack(alignment: .top, spacing: Style.metaSpacing) {
                Text(item.title)
                    .interFont(Constants.Typography.bodyM.withFace(.semibold))
                    .foregroundStyle(foreground)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)
                Group {
                    if let url = item.url {
                        IntentIconButton(icon: .external, label: "Open on GitHub", showsBackground: false) { openURL(url) }
                            .accessibilityIdentifier("pullRequest.openOnGitHub")
                    }
                    IntentIconButton(icon: .close, label: "Close", showsBackground: false) { dismiss() }
                        .accessibilityIdentifier("pullRequest.close")
                }
                // Center the buttons on the title's first line, not its box.
                .alignmentGuide(.top) { $0[.top] + Style.controlLift }
            }
            HStack(spacing: Style.metaSpacing) {
                HStack(spacing: Style.iconTextSpacing) {
                    Image(WorkspaceRowView.pillImage(for: item.status))
                        .resizable().scaledToFit()
                        .frame(width: iconSize, height: iconSize)
                        .foregroundStyle(PullRequestRowView.stateColor(item.status, colorScheme: colorScheme, contrast: contrast))
                        .accessibilityHidden(true)
                    metaText("#\(item.number)")
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(item.status.rawValue.capitalized) pull request #\(item.number)")
                if let author = item.author {
                    HStack(spacing: Style.iconTextSpacing) {
                        RepoOwnerAvatarView(owner: author, size: avatarSize, fallbackSymbol: "person.fill", cornerRadius: avatarSize / 2)
                            .accessibilityHidden(true)
                        metaText(author)
                    }
                }
                metaItem(.folder, "\(item.owner)/\(item.repo)")
            }
            if let head = store.detail?.headRef ?? item.headRef {
                metaItem(.gitBranch, store.detail?.baseRef.map { "\(head) → \($0)" } ?? head)
            }
        }
        .padding(.horizontal, Style.inset)
        .padding(.top, Style.inset)
        .padding(.bottom, Style.metaSpacing)
    }

    func metaItem(_ icon: ImageResource, _ text: String) -> some View {
        HStack(spacing: Style.iconTextSpacing) {
            Image(icon).resizable().scaledToFit()
                .frame(width: iconSize, height: iconSize)
                .foregroundStyle(secondary)
                .accessibilityHidden(true)
            metaText(text)
        }
    }

    func metaText(_ text: String) -> some View {
        Text(text)
            .interFont(Constants.Typography.bodyXS)
            .foregroundStyle(secondary)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    var tabBar: some View {
        HStack(alignment: .center, spacing: Style.tabSpacing) {
            ForEach(Tab.allCases, id: \.self) { candidate in
                Button { tab = candidate } label: {
                    Text(candidate.rawValue)
                        .interFont(Constants.Typography.bodyS)
                        .foregroundStyle(tab == candidate ? foreground : secondary)
                        .padding(.vertical, Style.tabVerticalPadding)
                        .overlay(alignment: .bottom) {
                            if tab == candidate {
                                Rectangle().fill(foreground).frame(height: Style.tabIndicatorHeight)
                            }
                        }
                }
                .buttonStyle(IntentContentButtonStyle())
                .accessibilityAddTraits(tab == candidate ? .isSelected : [])
                .accessibilityIdentifier("pullRequest.tab.\(candidate.rawValue)")
            }
            Spacer(minLength: Style.metaSpacing)
            if let linkedWorkspace {
                Button { onOpenWorkspace(linkedWorkspace.id) } label: {
                    HStack(spacing: Style.iconTextSpacing) {
                        Image(.folders).resizable().scaledToFit()
                            .frame(width: iconSize, height: iconSize)
                            .accessibilityHidden(true)
                        Text(linkedWorkspace.title)
                            .interFont(Constants.Typography.bodyXS)
                            .lineLimit(1)
                    }
                    .foregroundStyle(foreground)
                    .padding(.horizontal, Style.chipHorizontalPadding)
                    .padding(.vertical, Style.chipVerticalPadding)
                    .background(Capsule().fill(Constants.WorkspaceList.controlSurface(for: colorScheme)))
                }
                .buttonStyle(IntentContentButtonStyle())
                .accessibilityLabel("Open workspace \(linkedWorkspace.title)")
                .accessibilityIdentifier("pullRequest.workspace")
            }
        }
        .padding(.horizontal, Style.inset)
    }
}

// MARK: - Summary

private extension PullRequestDetailView {
    var summary: some View {
        VStack(alignment: .leading, spacing: Style.sectionSpacing) {
            reviewersSection
            Divider()
            checksSection
            Divider()
            description
        }
    }

    var reviewersSection: some View {
        VStack(alignment: .leading, spacing: Style.rowSpacing) {
            Text("Reviewers")
                .interFont(Constants.Typography.bodySEmphasized)
                .foregroundStyle(foreground)
                .accessibilityAddTraits(.isHeader)
            if store.loading.contains(.reviews), store.reviewers.isEmpty {
                ProgressView().frame(maxWidth: .infinity, alignment: .leading)
            } else if let error = store.errors[.reviews] {
                failure(error) { Task { await store.load(.reviews) } }
            } else if store.reviewers.isEmpty {
                muted("No reviews yet")
            } else {
                ForEach(store.reviewers) { reviewer in
                    HStack(spacing: Style.iconTextSpacing) {
                        RepoOwnerAvatarView(owner: reviewer.login, size: avatarSize, fallbackSymbol: "person.fill", cornerRadius: avatarSize / 2)
                            .accessibilityHidden(true)
                        Text(reviewer.login)
                            .interFont(Constants.Typography.bodyXS)
                            .foregroundStyle(foreground)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(reviewer.verdict)
                            .interFont(Constants.Typography.bodyXS)
                            .foregroundStyle(verdictColor(reviewer.state))
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    func verdictColor(_ state: String) -> Color {
        switch state {
        case "approved": Constants.Colors.WorkspaceStatus.prOpen
        case "changes_requested", "changes-requested": Theme.destructive(for: colorScheme)
        default: secondary
        }
    }

    @ViewBuilder var checksSection: some View {
        if store.loading.contains(.checks), store.checks.isEmpty {
            ProgressView().frame(maxWidth: .infinity, alignment: .leading)
        } else if let error = store.errors[.checks] {
            failure(error) { Task { await store.load(.checks) } }
        } else if let summary = PullRequestCheck.summary(store.checks) {
            VStack(alignment: .leading, spacing: Style.rowSpacing) {
                Button { withAnimation(.snappy) { showsChecks.toggle() } } label: {
                    HStack(spacing: Style.iconTextSpacing) {
                        checkIcon(summary.state)
                        Text(summary.label)
                            .interFont(Constants.Typography.bodyS)
                            .foregroundStyle(foreground)
                        Spacer()
                        Image(.chevronRight).resizable().scaledToFit()
                            .frame(width: iconSize, height: iconSize)
                            .rotationEffect(.degrees(showsChecks ? Style.expandedRotation : 0))
                            .foregroundStyle(secondary)
                            .accessibilityHidden(true)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(IntentContentButtonStyle())
                .accessibilityValue(showsChecks ? "Expanded" : "Collapsed")
                .accessibilityIdentifier("pullRequest.checks")
                if showsChecks {
                    ForEach(store.checks) { check in
                        Button { if let url = check.url { openURL(url) } } label: {
                            HStack(spacing: Style.iconTextSpacing) {
                                checkIcon(check.state)
                                Text(check.name)
                                    .interFont(Constants.Typography.bodyXS)
                                    .foregroundStyle(foreground)
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .buttonStyle(IntentContentButtonStyle())
                        .disabled(check.url == nil)
                    }
                }
            }
        } else {
            muted("No checks")
        }
    }

    func checkIcon(_ state: PullRequestCheck.State) -> some View {
        let appearance: (ImageResource, Color) = switch state {
        case .success: (.checkCircle, Constants.Colors.WorkspaceStatus.prOpen)
        case .failure, .cancelled: (.closeCircle, Theme.destructive(for: colorScheme))
        case .pending: (.historyCircle3, secondary)
        case .neutral: (.infoCircle, secondary)
        }
        return Image(appearance.0).resizable().scaledToFit()
            .frame(width: iconSize, height: iconSize)
            .foregroundStyle(appearance.1)
            .accessibilityHidden(true)
    }

    @ViewBuilder var description: some View {
        if let detail = store.detail {
            if detail.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                muted("No description")
            } else {
                MarkdownTextView(text: detail.body)
            }
        } else if let error = store.errors[.detail] {
            failure(error) { Task { await store.load(.detail) } }
        } else {
            ProgressView().frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Code

private extension PullRequestDetailView {
    @ViewBuilder var code: some View {
        if store.loading.contains(.files), store.files.isEmpty {
            ProgressView().frame(maxWidth: .infinity, alignment: .leading)
        } else if let error = store.errors[.files] {
            failure(error) { Task { await store.load(.files) } }
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
                        .padding(.top, Style.rowSpacing)
                }
            }
        }
    }

    func fileRow(_ file: PullRequestFile) -> some View {
        let expanded = expandedFiles.contains(file.id)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy) {
                    if expanded { expandedFiles.remove(file.id) } else { expandedFiles.insert(file.id) }
                }
            } label: {
                HStack(spacing: Style.iconTextSpacing) {
                    Text(file.filename)
                        .font(.footnote.monospaced())
                        .foregroundStyle(foreground)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    WorkspaceChangeStats(additions: file.additions, deletions: file.deletions)
                    Image(.chevronRight).resizable().scaledToFit()
                        .frame(width: iconSize, height: iconSize)
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
            if expanded {
                WorkspaceFileDiffView(
                    loader: nil,
                    path: file.filename,
                    isBinary: file.patch == nil,
                    embedded: true,
                    patchHunks: file.patch.map(WorkspaceDiffBuilder.hunks(patch:))
                )
                .clipShape(.rect(cornerRadius: Style.diffCornerRadius))
                .padding(.bottom, Style.fileRowPadding)
            }
        }
    }
}

// MARK: - Shared

private extension PullRequestDetailView {
    func muted(_ text: String) -> some View {
        Text(text)
            .interFont(Constants.Typography.bodyXS)
            .foregroundStyle(secondary)
    }

    func failure(_ message: String, retry: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: Style.rowSpacing) {
            muted(message)
            Button("Retry", action: retry)
                .buttonStyle(IntentButtonStyle(variant: .muted))
        }
    }
}

private enum Style {
    static let inset: CGFloat = 20
    static let metaSpacing: CGFloat = 12
    static let iconTextSpacing: CGFloat = 8
    static let controlLift: CGFloat = 10
    static let tabSpacing: CGFloat = 24
    static let tabVerticalPadding: CGFloat = 12
    static let tabIndicatorHeight: CGFloat = 2
    static let chipHorizontalPadding: CGFloat = 12
    static let chipVerticalPadding: CGFloat = 6
    static let sectionSpacing: CGFloat = 20
    static let rowSpacing: CGFloat = 10
    static let fileRowPadding: CGFloat = 12
    static let diffCornerRadius: CGFloat = 12
    static let expandedRotation: Double = 90
}
