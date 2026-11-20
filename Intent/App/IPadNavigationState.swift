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

enum IPadFocusPresentation: Equatable {
    case conversationEditing
    case normal
    case workspaceSearch
}

enum IPadShellLayoutMode: Equatable {
    case compact(drawerOpen: Bool)
    case overlay(drawerOpen: Bool)
    case split
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

struct IPadNavigationState: Equatable {
    private(set) var focusPresentation: IPadFocusPresentation = .normal
    private(set) var section: IPadSidebarSection = .workspaces
    private(set) var detail: IPadDetailSelection = .workspace
    private(set) var pairing: IPadPairingMode?
    private(set) var hasOpenedAssistant = false
    private(set) var layoutMode: IPadShellLayoutMode = .unmeasured
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

    mutating func updateLayout(usesOverlay: Bool, usesCompactNavigation: Bool = false, showsWorkspaceList: Bool = false) {
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
