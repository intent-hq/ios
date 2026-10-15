@testable import Intent
import Observation
import SwiftUI
import Testing
import UIKit

extension AppCoordinatorTests {
    @Test(.enabled("The host must publish accessible controls") {
        await SyntheticBadgeHost.publishesAccessibilityTree()
    })
    @MainActor func iPadWorkspaceBackFollowsWindowWidthAndKeepsSelection() async throws {
        let fixture = ConversationStartupFixture()
        defer { fixture.stop() }
        let coordinator = compactShellCoordinator(fixture)
        fixture.session.workspaceStore.workspaces = [Self.makeWorkspace(id: ConversationStartupFixture.workspaceId)]
        let size = CompactShellSize(width: CompactShellSize.wide)
        let shell = ResizableIPadTestShell(session: fixture.session, coordinator: coordinator, size: size)
        try await SyntheticBadgeHost.render(shell, width: CompactShellSize.wide, height: CompactShellSize.height) { host, _ in
            try waitForCompactShell {
                coordinator.selectedWorkspaceId == ConversationStartupFixture.workspaceId
                    && compactControl("ipad.rail.workspaces", in: host) != nil
            }
            #expect(compactControl("workspaceDetail.back", in: host) == nil)
            try recordCompactShell(in: host, width: size.width, name: "ipad-wide-workspace-no-back.png")
            size.width = CompactShellSize.narrow
            try waitForCompactShell { compactControl("workspaceDetail.back", in: host) != nil }
            let detail = coordinator.currentScreenDescription
            try recordCompactShell(in: host, width: size.width, name: "ipad-narrow-workspace-back.png")
            let back = try #require(compactControl("workspaceDetail.back", in: host))
            #expect(back.accessibilityActivate())
            try waitForCompactShell {
                coordinator.iPadNavigation.isSidebarVisible
                    && compactControl("workspaces.search.open", in: host) != nil
            }
            #expect(coordinator.currentScreenDescription == detail)
            #expect(coordinator.selectedWorkspaceId == ConversationStartupFixture.workspaceId)
            try recordCompactShell(in: host, width: size.width, name: "ipad-narrow-back-to-workspaces.png")
            size.width = CompactShellSize.wide
            try waitForCompactShell { compactControl("ipad.rail.workspaces", in: host) != nil }
            #expect(compactControl("workspaceDetail.back", in: host) == nil)
            #expect(coordinator.selectedWorkspaceId == ConversationStartupFixture.workspaceId)
            coordinator.iPadNavigation.collapseSidebar()
            #expect(compactControl("workspaceDetail.back", in: host) == nil)
        }
    }

    @Test(.enabled("The host must publish accessible controls") {
        await SyntheticBadgeHost.publishesAccessibilityTree()
    }, arguments: [ColorScheme.light, .dark])
    @MainActor func iPadCompactLaunchShowsListAndMenuDestinations(appearance: ColorScheme) async throws {
        let fixture = ConversationStartupFixture()
        defer { fixture.stop() }
        let coordinator = compactShellCoordinator(fixture)
        let size = CompactShellSize(width: CompactShellSize.narrow)
        let shell = ResizableIPadTestShell(session: fixture.session, coordinator: coordinator, size: size, appearance: appearance)
        try await SyntheticBadgeHost.render(shell, width: CompactShellSize.wide, height: CompactShellSize.height) { host, _ in
            try waitForCompactShell { coordinator.iPadNavigation.isSidebarVisible && compactControl("intent.menu.open", in: host) != nil }
            #expect(coordinator.iPadNavigation.section == .workspaces)
            #expect(compactControl("workspaces.search.open", in: host) != nil)
            #expect(compactControl("ipad.rail.workspaces", in: host) == nil)
            let originalLauncher = try #require(compactControl("intent.menu.open", in: host))
            let originalBottom = originalLauncher.accessibilityFrame.maxY
            try recordCompactShell(in: host, width: size.width, name: "ipad-narrow-workspaces-\(appearance).png")
            #expect(originalLauncher.accessibilityActivate())
            try waitForCompactShell { compactControl("intent.menu.close", in: host) != nil }
            try recordCompactShell(in: host, width: size.width, name: "ipad-narrow-menu-\(appearance).png")
            let close = try #require(compactControl("intent.menu.close", in: host))
            #expect(close.accessibilityActivate())
            for section in [IPadSidebarSection.settings, .connections, .assistant, .workspaces] {
                try selectCompactMenu(section.rawValue, in: host)
                try waitForCompactShell { coordinator.iPadNavigation.section == section && coordinator.iPadNavigation.isSidebarVisible }
                #expect(compactControl("ipad.sidebar.collapse", in: host) != nil)
                #expect(compactControls("intent.menu.open", in: host).count == 1)
            }
            try waitForCompactShell {
                guard let launcher = compactControl("intent.menu.open", in: host) else { return false }
                return abs(launcher.accessibilityFrame.maxY - originalBottom) < 1
            }
        }
    }

    @Test(.enabled("The host must publish accessible controls") {
        await SyntheticBadgeHost.publishesAccessibilityTree()
    }, arguments: [IPadDetailSelection.workspace, .assistant])
    @MainActor func iPadCompactResizeRetainsComposerAndDismissesOpenMenu(detail: IPadDetailSelection) async throws {
        let fixture = ConversationStartupFixture()
        defer { fixture.stop() }
        let coordinator = compactShellCoordinator(fixture)
        let workspaceId = detail == .assistant ? Workspace.chiefWorkspaceId : ConversationStartupFixture.workspaceId
        let startup = fixture.makeViewModel(workspaceId: workspaceId)
        await startup.load()
        if detail == .assistant {
            await fixture.session.assistantStore.refresh()
            try #require(!fixture.session.assistantStore.threads.isEmpty)
            coordinator.onSelectAssistant(agentId: ConversationStartupFixture.parentId)
        } else {
            coordinator.onSelectAgent(ConversationStartupFixture.parentId, workspaceId: ConversationStartupFixture.workspaceId, agentName: "Agent")
        }
        let size = CompactShellSize(width: CompactShellSize.wide)
        let shell = ResizableIPadTestShell(session: fixture.session, coordinator: coordinator, size: size)
        try await SyntheticBadgeHost.render(shell, width: CompactShellSize.wide, height: CompactShellSize.height) { host, _ in
            try verifyCompactResize(in: host, size: size, coordinator: coordinator, detail: detail)
        }
    }

    @Test(.enabled("The host must publish accessible controls") {
        await SyntheticBadgeHost.publishesAccessibilityTree()
    }, arguments: [IPadDetailSelection.workspace, .assistant])
    @MainActor func iPadTypingFocusRetainsEditorSelectionAcrossNarrowResize(detail: IPadDetailSelection) async throws {
        let fixture = ConversationStartupFixture()
        defer { fixture.stop() }
        let coordinator = compactShellCoordinator(fixture)
        if detail == .assistant {
            await fixture.session.assistantStore.refresh()
            try #require(!fixture.session.assistantStore.threads.isEmpty)
            coordinator.onSelectAssistant(agentId: ConversationStartupFixture.parentId)
        } else {
            coordinator.onSelectAgent(ConversationStartupFixture.parentId, workspaceId: ConversationStartupFixture.workspaceId, agentName: "Agent")
        }
        coordinator.iPadNavigation.collapseSidebar()
        let size = CompactShellSize(width: CompactShellSize.wide)
        let shell = ResizableIPadTestShell(session: fixture.session, coordinator: coordinator, size: size)
            .environment(\.accessibilityReduceMotion, true)
        try await SyntheticBadgeHost.render(shell, width: CompactShellSize.wide, height: CompactShellSize.height) { host, _ in
            try verifyFocusedEditor(in: host, size: size, coordinator: coordinator)
        }
    }

    @MainActor private func verifyFocusedEditor(in host: UIView, size: CompactShellSize, coordinator: AppCoordinator) throws {
        try waitForCompactShell { compactEditor(in: host) != nil }
        let editor = try #require(compactEditor(in: host))
        editor.text = "Keep this selected draft"
        editor.delegate?.textViewDidChange?(editor)
        let draft = editor.text
        let selection = CompactShellSize.draftSelection
        editor.selectedRange = selection
        let request = coordinator.conversationRequestId
        #expect(editor.becomeFirstResponder())
        try waitForCompactShell {
            coordinator.iPadNavigation.focusPresentation == .conversationEditing
                && compactControl("ipad.focus.close", in: host) != nil
        }
        for width in [CompactShellSize.narrow, CompactShellSize.wide] {
            size.width = width
            try waitForCompactShell {
                guard let close = compactControl("ipad.focus.close", in: host) else { return false }
                let frame = host.convert(close.accessibilityFrame, from: nil)
                return frame.minX >= 0 && frame.maxX <= width
            }
            #expect(compactEditor(in: host) === editor)
            #expect(editor.isFirstResponder)
            #expect(editor.text == draft)
            #expect(editor.selectedRange == selection)
            #expect(compactControl("ipad.rail.workspaces", in: host) == nil)
            #expect(compactControl("intent.menu.open", in: host) == nil)
        }
        let close = try #require(compactControl("ipad.focus.close", in: host))
        #expect(close.accessibilityActivate())
        try waitForCompactShell { coordinator.iPadNavigation.focusPresentation == .normal && !editor.isFirstResponder }
        #expect(compactEditor(in: host) === editor)
        #expect(editor.text == draft)
        #expect(editor.selectedRange == selection)
        #expect(!coordinator.iPadNavigation.isSidebarExpanded)
        #expect(coordinator.conversationRequestId == request)
    }

    @MainActor private func verifyCompactResize(
        in host: UIView, size: CompactShellSize, coordinator: AppCoordinator, detail: IPadDetailSelection
    ) throws {
        try waitForCompactShell { compactEditor(in: host) != nil && compactControl("ipad.rail.workspaces", in: host) != nil }
        let editor = try #require(compactEditor(in: host))
        editor.text = ""
        editor.delegate?.textViewDidChange?(editor)
        editor.insertText("Keep my draft across iPad resizing")
        let draft = editor.text
        let request = coordinator.conversationRequestId
        defer { editor.text = ""; editor.delegate?.textViewDidChange?(editor) }
        size.width = CompactShellSize.narrow
        try waitForCompactShell { compactControl("intent.menu.open", in: host) != nil && compactControl("ipad.rail.workspaces", in: host) == nil }
        #expect(compactControls("intent.menu.open", in: host).count == 1)
        let launcher = try #require(compactControl("intent.menu.open", in: host))
        try waitForCompactShell { launcher.accessibilityFrame.maxY <= editor.convert(editor.bounds, to: nil).minY }
        #expect(compactEditor(in: host) === editor)
        #expect(editor.text == draft)
        try verifyCompactControlBounds(in: host, width: size.width)
        try recordCompactShell(in: host, width: size.width, name: "ipad-narrow-\(detail)-draft.png")
        try selectCompactMenu("settings", in: host)
        let destination = detail == .assistant ? "assistant" : "workspaces"
        try selectCompactMenu(destination, in: host)
        let collapse = try #require(compactControl("ipad.sidebar.collapse", in: host))
        #expect(collapse.accessibilityActivate())
        try waitForCompactShell { !coordinator.iPadNavigation.isSidebarVisible }
        #expect(compactEditor(in: host) === editor)
        #expect(editor.text == draft)
        #expect(coordinator.iPadNavigation.detail == detail)
        #expect(coordinator.conversationRequestId == request)
        let open = try #require(compactControl("intent.menu.open", in: host))
        #expect(open.accessibilityActivate())
        try waitForCompactShell { compactControl("intent.menu.close", in: host) != nil }
        size.width = CompactShellSize.wide
        try waitForCompactShell { compactControl("ipad.rail.workspaces", in: host) != nil && compactControl("intent.menu.close", in: host) == nil }
        #expect(compactControl("intent.menu.open", in: host) == nil)
        #expect(coordinator.iPadNavigation.isSidebarExpanded)
        #expect(coordinator.iPadNavigation.isSidebarVisible)
        #expect(compactEditor(in: host) === editor)
        #expect(editor.text == draft)
        #expect(coordinator.conversationRequestId == request)
    }

    @MainActor private func compactShellCoordinator(_ fixture: ConversationStartupFixture) -> AppCoordinator {
        fixture.connection.currentPrincipal = InvitedSessionFixtures.principal("owner", role: .owner)
        let coordinator = AppCoordinator(
            workspaceStore: fixture.session.workspaceStore,
            connection: fixture.connection,
            persistence: persistence
        )
        coordinator.usesIPadShell = true
        coordinator.currentScreen = .workspaceList
        return coordinator
    }

    @MainActor private func verifyCompactControlBounds(in host: UIView, width: CGFloat) throws {
        let viewport = host.convert(CGRect(x: 0, y: 0, width: width, height: host.bounds.height), to: nil)
        let identifiers = ["composer.send", "composer.attachment", "intent.menu.open"]
        try waitForCompactShell {
            host.layoutIfNeeded()
            return identifiers.allSatisfy { identifier in
                guard let control = compactControl(identifier, in: host) else { return false }
                let frame = control.accessibilityFrame
                return frame.minX >= viewport.minX && frame.maxX <= viewport.maxX
            }
        }
        for identifier in identifiers {
            let control = try #require(compactControl(identifier, in: host))
            #expect(control.accessibilityFrame.minX >= viewport.minX)
            #expect(control.accessibilityFrame.maxX <= viewport.maxX)
        }
    }

    @MainActor private func recordCompactShell(in host: UIView, width: CGFloat, name: String) throws {
        let bounds = CGRect(x: 0, y: 0, width: width, height: host.bounds.height)
        var drawn = false
        let image = UIGraphicsImageRenderer(bounds: bounds).image { _ in
            drawn = host.drawHierarchy(in: host.bounds, afterScreenUpdates: true)
        }
        try #require(drawn, "The hosted narrow iPad shell could not be captured")
        Attachment.record(try #require(image.pngData()), named: name)
    }

    @MainActor private func selectCompactMenu(_ destination: String, in host: UIView) throws {
        try waitForCompactShell { compactControl("intent.menu.open", in: host) != nil }
        let open = try #require(compactControl("intent.menu.open", in: host))
        #expect(open.accessibilityActivate())
        try waitForCompactShell { compactControl("intent.menu.\(destination)", in: host) != nil }
        let action = try #require(compactControl("intent.menu.\(destination)", in: host))
        #expect(action.accessibilityActivate())
        try waitForCompactShell { compactControl("intent.menu.close", in: host) == nil }
    }

    @MainActor private func compactControl(_ identifier: String, in host: UIView) -> NSObject? {
        compactControls(identifier, in: host).first
    }

    @MainActor private func compactControls(_ identifier: String, in host: UIView) -> [NSObject] {
        SyntheticBadgeHost.accessibilityElements(in: host).filter { element in
            SyntheticBadgeHost.accessibilityIdentifier(of: element) == identifier && element.isAccessibilityElement
        }
    }

    @MainActor private func compactEditor(in host: UIView) -> KeyCommandTextView? {
        if let editor = host as? KeyCommandTextView { return editor }
        return host.subviews.lazy.compactMap { self.compactEditor(in: $0) }.first
    }

    @MainActor private func waitForCompactShell(sourceLocation: SourceLocation = #_sourceLocation, _ ready: () -> Bool) throws {
        let deadline = Date(timeIntervalSinceNow: CompactShellSize.timeout)
        while Date() < deadline {
            if ready() { return }
            _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: CompactShellSize.pollInterval))
        }
        try #require(ready(), "The retained iPad shell did not finish updating", sourceLocation: sourceLocation)
    }
}

@MainActor @Observable private final class CompactShellSize {
    static let draftSelection = NSRange(location: 5, length: 4)
    static let narrow: CGFloat = 320
    static let wide: CGFloat = 1210
    static let height: CGFloat = 900
    static let timeout: TimeInterval = 5
    static let pollInterval: TimeInterval = 0.01
    var width: CGFloat

    init(width: CGFloat) { self.width = width }
}

private struct ResizableIPadTestShell: View {
    let session: BackendSession
    let coordinator: AppCoordinator
    let size: CompactShellSize
    var appearance: ColorScheme = .light

    var body: some View {
        IPadShellView(session: session)
            .environment(session)
            .environment(coordinator)
            .environment(\.colorScheme, appearance)
            .transaction { $0.disablesAnimations = true }
            .frame(width: size.width)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
