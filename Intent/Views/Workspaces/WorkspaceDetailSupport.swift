import CoreText
import SwiftUI

struct WorkspaceDetailHeading: View {
    let workspaceId: String
    let title: String
    let createdAt: String?
    let repositoryOwner: String?
    let repositoryName: String?
    var statusMessage: String?
    var statusImageAssetId: String?
    @Bindable var titleEditor: WorkspaceTitleEditor
    var titleFocus: FocusState<Bool>.Binding?
    var topSpacing: CGFloat?
    var usesLargeTitle = false
    var showsTitle = true
    var usesSidebarTitle = false
    var showsOnlyTitle = false
    let onSaveTitle: () -> Void
    @FocusState private var titleFocused: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.usesDuoContextualRail) private var usesDuoContextualRail

    private var focusBinding: FocusState<Bool>.Binding { titleFocus ?? $titleFocused }
    private var titleStyle: Constants.Typography.Style {
        usesSidebarTitle ? IPadSidebarStyle.titleStyle : (usesLargeTitle ? Constants.Typography.heading1 : Constants.Typography.heading2)
    }
    private var titleTracking: CGFloat {
        usesSidebarTitle ? IPadSidebarStyle.titleTracking : (usesLargeTitle ? WorkspaceDetailStyle.largeTitleTracking : WorkspaceDetailStyle.titleTracking)
    }

    private var headingTopSpacing: CGFloat {
        if dynamicTypeSize.isAccessibilitySize { return WorkspaceDetailStyle.headingSpacing }
        return usesDuoContextualRail ? WorkspaceDetailStyle.pageInset : WorkspaceDetailStyle.headingTopSpacing
    }

    var body: some View {
        if showsOnlyTitle {
            editableTitle
        } else {
            headingContent
        }
    }

    private var headingContent: some View {
        VStack(alignment: .leading, spacing: titleEditor.isEditing
            ? WorkspaceDetailStyle.headingSpacing : WorkspaceDetailStyle.headingTextSpacing) {
            if showsTitle { editableTitle }
            if let repositoryOwner, let repositoryName {
                WorkspaceDetailHeadingText("\(repositoryOwner)/\(repositoryName)", style: Constants.Typography.subtextXXS)
                    .foregroundStyle(colorScheme == .light && colorSchemeContrast == .standard
                        ? WorkspaceDetailStyle.neutral
                        : WorkspaceDetailStyle.secondary(for: colorScheme, contrast: colorSchemeContrast))
            }
            if summary != nil || statusImageAssetId != nil { statusRow }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, WorkspaceDetailStyle.pageInset)
        .padding(.top, topSpacing ?? headingTopSpacing)
        .padding(.bottom, WorkspaceDetailStyle.headingBottomSpacing)
    }

    private var summary: String? {
        guard let trimmed = statusMessage?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// The status image leads the summary as a thumbnail; accessibility sizes stack it above.
    private var statusRow: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: WorkspaceDetailStyle.headingSpacing))
            : AnyLayout(HStackLayout(spacing: WorkspaceDetailStyle.headingTextSpacing))
        return layout {
            if let statusImageAssetId {
                WorkspaceStatusImageView(workspaceId: workspaceId, assetId: statusImageAssetId)
            }
            if let summary {
                WorkspaceDetailHeadingText(summary, style: Constants.Typography.bodyS)
                    .tracking(WorkspaceDetailStyle.bodyTracking)
                    .foregroundStyle(WorkspaceDetailStyle.secondary(for: colorScheme, contrast: colorSchemeContrast))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("workspaceDetail.summary")
            }
        }
    }

    @ViewBuilder
    private var editableTitle: some View {
        if titleEditor.isEditing {
            TextField("New Workspace", text: $titleEditor.draft)
                .textFieldStyle(.plain)
                .interFont(titleStyle)
                .tracking(titleTracking)
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
                WorkspaceDetailHeadingText(title, style: titleStyle)
                    .tracking(titleTracking)
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
    let onCreateAgent: () -> Void
    let onTerminal: () -> Void
    let onBrowser: () -> Void

    var body: some View {
        VStack(spacing: IPadShellLayout.contextualRailSpacing) {
            IntentIconButton(icon: .addCircle, label: "Create New Agent", showsBackground: false, action: onCreateAgent)
                .accessibilityIdentifier("workspace.shortcut.createAgent")
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
    var onCollapseSidebar: (() -> Void)?
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
            sidebarAction
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

    @ViewBuilder
    private var sidebarAction: some View {
        if let onCollapseSidebar {
            Button(action: onCollapseSidebar) {
                Label { Text("Hide sidebar") } icon: { Image(.collapseLeft) }
            }
            .accessibilityIdentifier("ipad.sidebar.collapse")
            Divider()
        }
    }
}

struct WorkspaceDetailHeader: View {
    let workspaceId: String
    let workspace: Workspace?
    let title: String
    @Binding var selection: WorkspaceTab
    let titleEditor: WorkspaceTitleEditor
    let titleFocus: FocusState<Bool>.Binding
    var headingTopSpacing: CGFloat?
    var usesLargeTitle = false
    var showsTitle = true
    let onSaveTitle: () -> Void

    var body: some View {
        WorkspaceDetailHeading(
            workspaceId: workspaceId,
            title: title,
            createdAt: workspace?.createdAt,
            repositoryOwner: workspace?.repositoryOwner,
            repositoryName: workspace?.repositoryName,
            statusMessage: workspace?.statusMessage,
            statusImageAssetId: WorkspaceStatusImageLayout.assetId(for: workspace),
            titleEditor: titleEditor,
            titleFocus: titleFocus,
            topSpacing: headingTopSpacing,
            usesLargeTitle: usesLargeTitle,
            showsTitle: showsTitle,
            onSaveTitle: onSaveTitle
        )
        #if !os(visionOS)
        WorkspaceContentTabs(selection: $selection)
            .padding(.horizontal, WorkspaceDetailStyle.pageInset)
            .padding(.top, Constants.WorkspaceDetail.tabVerticalPadding)
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
