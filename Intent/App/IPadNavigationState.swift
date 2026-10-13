import Foundation

enum IPadSidebarSection: String, CaseIterable {
    case assistant
    case connections
    case settings
    case workspaces
}

enum IPadDetailSelection: Equatable {
    case assistant
    case workspace
}

enum IPadPairingMode: Equatable {
    case manual
    case qrCode
}

/// Window-owned presentation state, independent of the backend and workspace route.
struct IPadNavigationState: Equatable {
    private(set) var section: IPadSidebarSection = .workspaces
    private(set) var detail: IPadDetailSelection = .workspace
    private(set) var pairing: IPadPairingMode?
    private(set) var hasOpenedAssistant = false
    private(set) var isSidebarExpanded = true
    private(set) var isDrawerPresented = false
    private(set) var usesSidebarOverlay = false
    private(set) var usesCompactNavigation = false
    private(set) var hasMeasuredLayout = false

    var isSidebarVisible: Bool {
        usesSidebarOverlay ? isDrawerPresented : isSidebarExpanded
    }

    mutating func selectSection(_ section: IPadSidebarSection) {
        self.section = section
        switch section {
        case .assistant:
            detail = .assistant
            hasOpenedAssistant = true
            pairing = nil
        case .workspaces:
            detail = .workspace
            pairing = nil
        case .connections, .settings:
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
        section = .assistant
        detail = .assistant
        hasOpenedAssistant = true
        pairing = nil
        detailWasSelected()
    }

    mutating func presentPairing(_ mode: IPadPairingMode) {
        pairing = mode
        detailWasSelected()
    }

    mutating func cancelPairing() {
        pairing = nil
        if usesCompactNavigation { revealSidebar() }
    }

    mutating func revealSidebar() {
        if usesSidebarOverlay {
            isDrawerPresented = true
        } else {
            isSidebarExpanded = true
        }
    }

    mutating func collapseSidebar() {
        if usesSidebarOverlay {
            isDrawerPresented = false
        } else {
            isSidebarExpanded = false
        }
    }

    mutating func updateLayout(usesOverlay: Bool, usesCompactNavigation: Bool = false, showsWorkspaceList: Bool = false) {
        hasMeasuredLayout = true
        guard usesSidebarOverlay != usesOverlay || self.usesCompactNavigation != usesCompactNavigation else { return }
        usesSidebarOverlay = usesOverlay
        self.usesCompactNavigation = usesCompactNavigation
        // Rotation preserves the wide-window preference, without unexpectedly
        // opening a drawer over the conversation in a narrow window.
        isDrawerPresented = false
        if usesCompactNavigation, pairing == nil,
           section == .settings || section == .connections || (detail == .workspace && showsWorkspaceList) {
            revealSidebar()
        }
    }

    mutating func revokeAssistantAccess() {
        hasOpenedAssistant = false
        if detail == .assistant { detail = .workspace }
        if section == .assistant { section = .workspaces }
    }

    private mutating func detailWasSelected() {
        isDrawerPresented = false
    }
}
