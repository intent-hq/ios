import CoreText
import SwiftUI

struct WorkspaceDetailHeading: View {
    let workspaceId: String
    let title: String
    let createdAt: String?
    let repositoryOwner: String?
    let repositoryName: String?
    var statusMessage: String?
    @Bindable var titleEditor: WorkspaceTitleEditor
    var titleFocus: FocusState<Bool>.Binding?
    let onSaveTitle: () -> Void
    @FocusState private var titleFocused: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.usesDuoContextualRail) private var usesDuoContextualRail

    private var focusBinding: FocusState<Bool>.Binding { titleFocus ?? $titleFocused }

    private var headingTopSpacing: CGFloat {
        if dynamicTypeSize.isAccessibilitySize { return WorkspaceDetailStyle.headingSpacing }
        return usesDuoContextualRail ? WorkspaceDetailStyle.pageInset : WorkspaceDetailStyle.headingTopSpacing
    }

    var body: some View {
        VStack(alignment: .leading, spacing: titleEditor.isEditing
            ? WorkspaceDetailStyle.headingSpacing : WorkspaceDetailStyle.headingTextSpacing) {
            editableTitle
            if let repositoryOwner, let repositoryName {
                WorkspaceDetailHeadingText("\(repositoryOwner)/\(repositoryName)", style: Constants.Typography.subtextXXS)
                    .foregroundStyle(colorScheme == .light && colorSchemeContrast == .standard
                        ? WorkspaceDetailStyle.neutral
                        : WorkspaceDetailStyle.secondary(for: colorScheme, contrast: colorSchemeContrast))
            }
            if let summary = statusMessage?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
                WorkspaceDetailHeadingText(summary, style: Constants.Typography.bodyS)
                    .tracking(WorkspaceDetailStyle.bodyTracking)
                    .foregroundStyle(WorkspaceDetailStyle.secondary(for: colorScheme, contrast: colorSchemeContrast))
                    .accessibilityIdentifier("workspaceDetail.summary")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, WorkspaceDetailStyle.pageInset)
        .padding(.top, headingTopSpacing)
        .padding(.bottom, WorkspaceDetailStyle.headingBottomSpacing)
    }

    @ViewBuilder
    private var editableTitle: some View {
        if titleEditor.isEditing {
            TextField("New Workspace", text: $titleEditor.draft)
                .textFieldStyle(.plain)
                .interFont(Constants.Typography.heading2)
                .tracking(WorkspaceDetailStyle.titleTracking)
                .foregroundStyle(WorkspaceDetailStyle.foreground(for: colorScheme))
                .submitLabel(.done)
                .focused(focusBinding)
                .disabled(titleEditor.isSaving)
                .onAppear { focusBinding.wrappedValue = true }
                .onChange(of: titleEditor.isSaving) { _, saving in
                    if !saving { focusBinding.wrappedValue = true }
                }
                .onSubmit(onSaveTitle)
                .accessibilityLabel("Workspace name")
                .accessibilityIdentifier("workspace.title.field")
            if let error = titleEditor.errorMessage {
                Text(error)
                    .interFont(Constants.Typography.bodyS)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("workspace.title.error")
            }
        } else {
            WorkspaceTitle(title: title, createdAt: createdAt) { title in
                WorkspaceDetailHeadingText(title, style: Constants.Typography.heading2)
                    .tracking(WorkspaceDetailStyle.titleTracking)
            }
            .foregroundStyle(WorkspaceDetailStyle.foreground(for: colorScheme))
            .contentShape(Rectangle())
            .onTapGesture(count: 2, perform: beginEditing)
            .accessibilityAddTraits(.isHeader)
            .accessibilityHint("Double-tap to edit the workspace name")
            .accessibilityAction(.default, beginEditing)
            .accessibilityAction(named: "Edit workspace name", beginEditing)
            .accessibilityIdentifier("workspace.title.heading")
        }
    }

    private func beginEditing() {
        titleEditor.begin(workspaceId: workspaceId, title: title)
    }
}

private struct WorkspaceDetailHeadingText: View {
    let text: String
    let style: Constants.Typography.Style
    @Environment(\.legibilityWeight) private var legibilityWeight
    @ScaledMetric private var fontSize: CGFloat

    init(_ text: String, style: Constants.Typography.Style) {
        self.text = text
        self.style = style
        _fontSize = ScaledMetric(wrappedValue: style.size, relativeTo: style.relativeTo)
    }

    var body: some View {
        let face = legibilityWeight == .bold ? style.face.legibleFace : style.face
        let font = CTFontCreateWithName(face.rawValue as CFString, fontSize, nil)
        WorkspaceTextTrimLayout(capHeight: CTFontGetCapHeight(font)) {
            Text(text)
                .interFont(style)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct WorkspaceTaskProgressLayout: Equatable {
    let total: Int
    let completed: Int
    let inProgress: Int
    let remaining: Int

    init?(total: Int, completed: Int, inProgress: Int) {
        guard total > 0 else { return nil }
        self.total = total
        self.completed = min(max(0, completed), total)
        self.inProgress = min(max(0, inProgress), total - self.completed)
        self.remaining = total - self.completed - self.inProgress
    }

    var visibleSegmentCount: Int {
        [completed, inProgress, remaining].count { $0 > 0 }
    }

    var summary: String {
        "\(completed) of \(total) tasks complete"
            + (inProgress > 0 ? ", \(inProgress) in progress" : "")
    }

    func segmentWidth(
        for count: Int,
        in measuredWidth: CGFloat,
        spacing: CGFloat
    ) -> CGFloat {
        let totalSpacing = spacing * CGFloat(max(0, visibleSegmentCount - 1))
        let distributableWidth = max(0, measuredWidth - totalSpacing)
        return distributableWidth * CGFloat(count) / CGFloat(total)
    }
}

struct WorkspaceTaskProgressView: View {
    let progress: WorkspaceTaskProgressLayout

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @State private var progressWidth: CGFloat = 0

    var body: some View {
        progressBar
            .padding(.horizontal, WorkspaceDetailStyle.pageInset)
            .padding(.bottom, WorkspaceDetailStyle.progressBottomSpacing)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Task progress")
            .accessibilityValue(progress.summary)
    }

    private var progressBar: some View {
        HStack(spacing: Constants.WorkspaceDetail.progressSpacing) {
            progressSegment(count: progress.completed, color: WorkspaceDetailStyle.foreground(for: colorScheme))
            progressSegment(count: progress.inProgress, color: WorkspaceDetailStyle.accent)
            remainingProgressSegment
        }
        // Accept a narrower proposal even while segments still use the previous measurement.
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .frame(height: WorkspaceDetailStyle.progressHeight)
        .clipShape(Capsule())
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { progressWidth = $0 }
        .overlay { progressBorder }
    }

    @ViewBuilder
    private func progressSegment(count: Int, color: Color) -> some View {
        if count > 0 {
            Rectangle()
                .fill(color)
                .frame(width: segmentWidth(for: count))
        }
    }

    @ViewBuilder
    private var remainingProgressSegment: some View {
        if progress.remaining > 0 {
            Rectangle()
                .fill(WorkspaceDetailStyle.surface(for: colorScheme))
                .frame(width: segmentWidth(for: progress.remaining))
        }
    }

    private func segmentWidth(for count: Int) -> CGFloat {
        progressWidth > 0
            ? progress.segmentWidth(
                for: count,
                in: progressWidth,
                spacing: Constants.WorkspaceDetail.progressSpacing
            )
            : 0
    }

    @ViewBuilder
    private var progressBorder: some View {
        if colorSchemeContrast == .increased {
            Capsule()
                .strokeBorder(
                    Theme.border(for: colorScheme, contrast: colorSchemeContrast),
                    lineWidth: Constants.WorkspaceDetail.increasedContrastProgressBorderWidth
                )
        }
    }
}

enum WorkspaceDetailHeaderLayout {
    static func tabTopPadding(hasTaskProgress: Bool) -> CGFloat {
        hasTaskProgress ? 0 : Constants.WorkspaceDetail.tabVerticalPadding
    }
}

struct WorkspaceDetailToolbarTitle: View {
    let title: String
    let createdAt: String?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: WorkspaceDetailStyle.tabInset) {
            WorkspaceTitle(title: title, createdAt: createdAt) { title in
                Text(title).interFont(Constants.Typography.bodyXSEmphasized)
            }
            .foregroundStyle(WorkspaceDetailStyle.foreground(for: colorScheme))
            Text("Workspace")
                .interFont(Constants.Typography.bodyXS)
                .foregroundStyle(WorkspaceDetailStyle.secondary(for: colorScheme))
        }
        .lineLimit(1)
    }
}

struct WorkspaceDetailToolbarPicker: View {
    @Binding var selection: WorkspaceTab

    var body: some View {
        Picker("Workspace Content", selection: $selection) {
            Label { Text("Agents").interFont(Constants.Typography.bodyXS) } icon: { Image(.agents) }
                .tag(WorkspaceTab.agents)
            Label { Text("Context").interFont(Constants.Typography.bodyXS) } icon: { Image(.file) }
                .tag(WorkspaceTab.context)
            Label { Text("Changes").interFont(Constants.Typography.bodyXS) } icon: { Image(.gitDiff) }
                .tag(WorkspaceTab.changes)
        }
        .pickerStyle(.segmented)
    }
}

struct WorkspaceRailShortcuts: View {
    let isTerminalDisabled: Bool
    let onTerminal: () -> Void
    let onBrowser: () -> Void

    var body: some View {
        VStack(spacing: IPadShellLayout.contextualRailSpacing) {
            IntentIconButton(icon: .terminal, label: "Open terminal", showsBackground: false, action: onTerminal)
                .disabled(isTerminalDisabled)
                .accessibilityIdentifier("workspace.shortcut.terminal")
            IntentIconButton(icon: .globe, label: "Open browser", showsBackground: false, action: onBrowser)
                .accessibilityIdentifier("workspace.shortcut.browser")
        }
    }
}

struct WorkspaceActionsMenu: View {
    let workspaceId: String
    let scriptStore: WorkspaceScriptStore
    let isTerminalDisabled: Bool
    let onCreateAgent: () -> Void
    let onCreateTerminal: () -> Void
    let onCreateBrowser: () -> Void
    var onTransfer: (() -> Void)?
    let onArchive: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Menu {
            Button(action: onCreateAgent) {
                Label { Text("Create New Agent").interFont(Constants.Typography.bodyS) } icon: { Image(.addCircle) }
            }
            Button(action: onCreateTerminal) {
                Label { Text("New terminal").interFont(Constants.Typography.bodyS) } icon: { Image(.terminal) }
            }
            .disabled(isTerminalDisabled)
            Button(action: onCreateBrowser) {
                Label { Text("New browser").interFont(Constants.Typography.bodyS) } icon: { Image(.globe) }
            }
            WorkspaceScriptsMenu(workspaceId: workspaceId, store: scriptStore)
            Divider()
            if let onTransfer {
                Button(action: onTransfer) {
                    Label { Text("Transfer workspace").interFont(Constants.Typography.bodyS) } icon: {
                        Image(.truckOne)
                    }
                }
                .accessibilityIdentifier("workspace.transfer")
            }
            Button(action: onArchive) {
                Label { Text("Archive").interFont(Constants.Typography.bodyS) } icon: { Image(.archive) }
            }
            Button(role: .destructive, action: onDelete) {
                Label { Text("Delete").interFont(Constants.Typography.bodyS) } icon: { Image(.delete) }
            }
        } label: {
            ToolbarOverflowLabel()
        }
        .buttonStyle(IntentContentButtonStyle())
        .accessibilityLabel("Workspace actions")
    }
}

struct WorkspaceDetailHeader: View {
    let workspaceId: String
    let workspace: Workspace?
    let title: String
    @Binding var selection: WorkspaceTab
    let titleEditor: WorkspaceTitleEditor
    let titleFocus: FocusState<Bool>.Binding
    let onSaveTitle: () -> Void

    var body: some View {
        WorkspaceDetailHeading(
            workspaceId: workspaceId,
            title: title,
            createdAt: workspace?.createdAt,
            repositoryOwner: workspace?.repositoryOwner,
            repositoryName: workspace?.repositoryName,
            statusMessage: workspace?.statusMessage,
            titleEditor: titleEditor,
            titleFocus: titleFocus,
            onSaveTitle: onSaveTitle
        )
        if let assetId = WorkspaceStatusImageLayout.assetId(for: workspace) {
            WorkspaceStatusImageView(workspaceId: workspaceId, assetId: assetId)
                .padding(.horizontal, WorkspaceDetailStyle.pageInset)
                .padding(.bottom, Constants.WorkspaceDetail.statusImageBottomPadding)
        }
        if let total = workspace?.taskStatsTotal,
           let progress = WorkspaceTaskProgressLayout(
               total: total,
               completed: workspace?.taskStatsCompleted ?? 0,
               inProgress: workspace?.taskStatsInProgress ?? 0
           ) {
            WorkspaceTaskProgressView(progress: progress)
        }
        #if !os(visionOS)
        WorkspaceContentTabs(selection: $selection)
            .padding(.horizontal, WorkspaceDetailStyle.pageInset)
            .padding(.top, WorkspaceDetailHeaderLayout.tabTopPadding(
                hasTaskProgress: (workspace?.taskStatsTotal ?? 0) > 0
            ))
            .padding(.bottom, WorkspaceDetailStyle.sectionSpacing)
        #endif
    }
}

struct WorkspaceDetailResources: View {
    let workspaceId: String
    let terminalStore: MobileTerminalStore
    let browserStore: WorkspaceBrowserStore
    let scriptStore: WorkspaceScriptStore
    @Binding var revealedTarget: WorkspaceSwipeTarget?
    let followsAgents: Bool
    let onSelectTerminal: (MobileTerminal) -> Void
    let onSelectBrowser: (WorkspaceBrowser) -> Void

    private var showsTerminals: Bool { !terminalStore.activeTerminals(workspaceId: workspaceId).isEmpty }

    private var showsBrowsers: Bool {
        !browserStore.browsers(workspaceId: workspaceId).isEmpty || browserStore.errorMessage(workspaceId: workspaceId) != nil
    }

    private var showsScripts: Bool {
        !scriptStore.scriptsWithRuns(workspaceId: workspaceId).isEmpty || scriptStore.errorMessage(workspaceId: workspaceId) != nil
    }

    var body: some View {
        if showsTerminals {
            WorkspaceMobileTerminalsView(
                workspaceId: workspaceId,
                store: terminalStore,
                revealedTarget: $revealedTarget,
                onSelect: onSelectTerminal
            )
            .padding(.horizontal, WorkspaceDetailStyle.pageInset)
            .padding(.top, followsAgents ? WorkspaceDetailStyle.rowSpacing : 0)
            .id("workspace.resources.terminals")
        }
        if showsBrowsers {
            WorkspaceBrowsersView(
                workspaceId: workspaceId,
                store: browserStore,
                revealedTarget: $revealedTarget,
                onSelect: onSelectBrowser
            )
            .padding(.horizontal, WorkspaceDetailStyle.pageInset)
            .padding(.top, followsAgents || showsTerminals ? WorkspaceDetailStyle.rowSpacing : 0)
            .id("workspace.resources.browsers")
        }
        if showsScripts {
            WorkspaceScriptsView(workspaceId: workspaceId, store: scriptStore, revealedTarget: $revealedTarget)
                .padding(.horizontal, WorkspaceDetailStyle.pageInset)
                .padding(.top, followsAgents || showsTerminals || showsBrowsers ? WorkspaceDetailStyle.rowSpacing : 0)
                .id("workspace.resources.scripts")
        }
    }
}

#if os(visionOS)
struct WorkspaceActionConfirmationSheet: View {
    let title: String
    let message: String
    let actionLabel: String
    let isDestructive: Bool
    let onConfirm: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: Constants.WorkspaceDetail.confirmationSheetSpacing) {
            Text(title).interFont(Constants.Typography.heading2)
            Text(message).interFont(Constants.Typography.bodyS)
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
            Button(role: isDestructive ? .destructive : nil) {
                dismiss()
                onConfirm()
            } label: {
                Text(actionLabel).interFont(Constants.Typography.bodyS)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(IntentButtonStyle())
            Button {
                dismiss()
            } label: {
                Text("Cancel").interFont(Constants.Typography.bodyS)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(IntentButtonStyle(variant: .secondary))
        }
        .padding(Constants.WorkspaceDetail.confirmationSheetPadding)
        .frame(width: Constants.WorkspaceDetail.confirmationSheetWidth)
    }
}
#endif
