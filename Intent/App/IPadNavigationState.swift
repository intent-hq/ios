import Foundation

enum IPadSidebarSection: String, CaseIterable {
    case assistant
    case connections
    case pullRequests
    case settings
    case workspaces
}

enum IPadDetailSelection: Equatable {
    case assistant
    case pullRequest
    case workspace
}

enum IPadPairingMode: Equatable {
    case manual
    case qrCode
}

/// Explicit input presentation; keyboard notifications never change this state.
enum IPadFocusPresentation: Equatable {
    case conversationEditing
    case normal
    case workspaceSearch
}

/// How the shell lays out its sidebar at the current width.
/// Only overlay widths have a drawer; nothing is known before the first measurement.
enum IPadShellLayoutMode: Equatable {
    /// Narrow windows: the drawer fills the width and the rail is hidden.
    case compact(drawerOpen: Bool)
    /// The sidebar is a drawer over the detail.
    case overlay(drawerOpen: Bool)
    /// The sidebar sits beside the detail and follows `isSidebarExpanded`.
    case split
    /// Before the first measurement; the sidebar behaves as in `split`.
    case unmeasured

    var usesOverlay: Bool {
        switch self {
        case .compact, .overlay: true
        case .split, .unmeasured: false
        }
    }

    var isDrawerOpen: Bool {
        switch self {
        case .compact(let open), .overlay(let open): open
        case .split, .unmeasured: false
        }
    }

    func withDrawer(open: Bool) -> Self {
        switch self {
        case .compact: .compact(drawerOpen: open)
        case .overlay: .overlay(drawerOpen: open)
        case .split, .unmeasured: self
        }
    }
}

/// Window-owned presentation state, independent of the backend and workspace route.
struct IPadNavigationState: Equatable {
    private(set) var focusPresentation: IPadFocusPresentation = .normal
    private(set) var section: IPadSidebarSection = .workspaces
    private(set) var detail: IPadDetailSelection = .workspace
    private(set) var pairing: IPadPairingMode?
    private(set) var hasOpenedAssistant = false
    private(set) var layoutMode: IPadShellLayoutMode = .unmeasured
    /// The wide-window choice; it survives trips through overlay and compact widths.
    private(set) var isSidebarExpanded = true
    private(set) var mainTool: IPadWorkspaceTool?
    let toolDragWindowId = UUID()

    var hasMeasuredLayout: Bool { layoutMode != .unmeasured }
    var usesSidebarOverlay: Bool { layoutMode.usesOverlay }
    var usesCompactNavigation: Bool {
        if case .compact = layoutMode { return true }
        return false
    }
    var isDrawerPresented: Bool { layoutMode.isDrawerOpen }

    var canPlaceTool: Bool {
        layoutMode == .split && pairing == nil && section == .workspaces
    }

    @discardableResult
    mutating func placeTool(_ tool: IPadWorkspaceTool) -> Bool {
        guard canPlaceTool else { return false }
        mainTool = tool
        focusPresentation = .normal
        detail = .workspace
        revealSidebar()
        return true
    }

    mutating func closeTool() { mainTool = nil }

    var isSidebarVisible: Bool {
        usesSidebarOverlay ? isDrawerPresented : isSidebarExpanded
    }

    mutating func selectSection(_ section: IPadSidebarSection) {
        focusPresentation = .normal
        self.section = section
        switch section {
        case .assistant:
            detail = .assistant
            hasOpenedAssistant = true
            pairing = nil
        case .workspaces:
            detail = .workspace
            pairing = nil
        case .connections, .pullRequests, .settings:
            break
        }
        revealSidebar()
    }

    mutating func showWorkspaceDetail() {
        section = .workspaces
        detail = .workspace
        pairing = nil
        detailWasSelected()
    }

    mutating func showAssistantDetail() {
        closeTool()
        section = .assistant
        detail = .assistant
        hasOpenedAssistant = true
        pairing = nil
        detailWasSelected()
    }

    mutating func showPullRequestDetail() {
        section = .pullRequests
        detail = .pullRequest
        pairing = nil
        detailWasSelected()
    }

    /// Closing a pull request returns the main pane to the workspace and keeps the sidebar.
    mutating func closePullRequestDetail() {
        if detail == .pullRequest { detail = .workspace }
    }

    mutating func presentPairing(_ mode: IPadPairingMode) {
        pairing = mode
        detailWasSelected()
    }

    mutating func cancelPairing() {
        pairing = nil
        if usesCompactNavigation { revealSidebar() }
    }

    mutating func revealSidebar() { setSidebarVisible(true) }

    mutating func collapseSidebar() { setSidebarVisible(false) }

    private mutating func setSidebarVisible(_ visible: Bool) {
        if usesSidebarOverlay {
            layoutMode = layoutMode.withDrawer(open: visible)
        } else {
            isSidebarExpanded = visible
        }
    }

    mutating func prepareForConnectionSwitcher(showingWorkspaceList: Bool) {
        guard usesSidebarOverlay else { return }
        guard !usesCompactNavigation || !showingWorkspaceList || section != .workspaces else { return }
        collapseSidebar()
    }

    /// `IPadShellLayout` only reports compact navigation at overlay widths, so compact implies overlay here.
    mutating func updateLayout(usesOverlay: Bool, usesCompactNavigation: Bool = false, showsWorkspaceList: Bool = false) {
        // Rotation preserves the wide-window preference, without unexpectedly
        // opening a drawer over the conversation in a narrow window.
        let measured: IPadShellLayoutMode = usesCompactNavigation ? .compact(drawerOpen: false)
            : usesOverlay ? .overlay(drawerOpen: false) : .split
        guard measured != layoutMode.withDrawer(open: false) else { return }
        let layoutChanged = measured != .split || layoutMode != .unmeasured
        layoutMode = measured
        guard layoutChanged else { return }
        if measured != .split { closeTool() }
        if usesCompactNavigation, pairing == nil,
           section == .settings || section == .connections || section == .pullRequests
           || (detail == .workspace && showsWorkspaceList) {
            revealSidebar()
        }
    }

    mutating func revokeAssistantAccess() {
        if detail == .assistant { focusPresentation = .normal }
        hasOpenedAssistant = false
        if detail == .assistant { detail = .workspace }
        if section == .assistant { section = .workspaces }
    }

    mutating func setFocusPresentation(_ presentation: IPadFocusPresentation) {
        guard pairing == nil || presentation == .normal else { return }
        guard presentation != .workspaceSearch || section == .workspaces else { return }
        focusPresentation = presentation
    }

    private mutating func detailWasSelected() {
        focusPresentation = .normal
        layoutMode = layoutMode.withDrawer(open: false)
    }
}
