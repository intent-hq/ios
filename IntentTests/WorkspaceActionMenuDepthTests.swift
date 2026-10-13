import Foundation
@testable import Intent
import Observation
import PhotosUI
import SwiftUI
import Testing
import UIKit

/// The Intent menu on visionOS: its action cards come forward in depth, the
/// unread attention rows that lift out of the window plane are fully hidden
/// while it is open, and the open menu temporarily covers the floating chat
/// composer. The visionOS branches cannot run in the iOS test host, so the
/// platform-neutral rules are pinned directly and the wiring through source.
@MainActor
@Suite(.serialized)
struct WorkspaceActionMenuDepthTests {
    // MARK: - Raised attention rows while the menu is open

    @Test func closedMenuKeepsAttentionRowsRaised() {
        let presentation = WorkspaceAttentionCuePresentation.resolve(needsInput: true, actionMenuOpen: false)
        #expect(presentation == .raised)
        #expect(presentation.liftsTowardViewer)
        #expect(!presentation.isHidden)
    }

    @Test func openMenuHidesRaisedRowsEntirely() {
        // Flattening or blurring is not enough: the row is invisible, takes
        // no input and leaves the accessibility tree.
        let presentation = WorkspaceAttentionCuePresentation.resolve(needsInput: true, actionMenuOpen: true)
        #expect(presentation == .suppressed)
        #expect(presentation.isHidden)
        #expect(!presentation.liftsTowardViewer)
    }

    @Test func rowsWithoutAttentionAreUnaffectedByTheMenu() {
        #expect(WorkspaceAttentionCuePresentation.resolve(needsInput: false, actionMenuOpen: false) == .resting)
        #expect(WorkspaceAttentionCuePresentation.resolve(needsInput: false, actionMenuOpen: true) == .resting)
        #expect(!WorkspaceAttentionCuePresentation.resting.isHidden)
        #expect(!WorkspaceAttentionCuePresentation.resting.liftsTowardViewer)
    }

    @Test func activityArrivingWhileOpenStaysHiddenUntilDismissal() {
        // A workspace raises attention while the menu is open: it must go
        // straight to hidden, never through a raised frame.
        var workspace = Self.workspace(attention: nil)
        var sequence = [WorkspaceAttentionCuePresentation.resolve(for: workspace, actionMenuOpen: true)]
        workspace = Self.workspace(attention: "unread")
        sequence.append(.resolve(for: workspace, actionMenuOpen: true))
        sequence.append(.resolve(for: workspace, actionMenuOpen: false))
        #expect(sequence == [.resting, .suppressed, .raised])
    }

    @Test func openAndDismissPreservesUnreadState() {
        // Suppression is presentation only: the stored workspace (and its
        // server-owned unread flag) is never touched.
        let workspace = Self.workspace(attention: "unread")
        for open in [true, false, true, false] {
            _ = WorkspaceAttentionCuePresentation.resolve(for: workspace, actionMenuOpen: open)
        }
        #expect(workspace.attention == "unread")
        #expect(hasUnreadAttention(workspace))
        #expect(WorkspaceAttentionCuePresentation.resolve(for: workspace, actionMenuOpen: false) == .raised)
    }

    @Test func blockedAndQuestionRowsAreHiddenToo() {
        for status in ["blocked", "needs_attention"] {
            let workspace = Self.workspace(attention: nil, displayStatus: status)
            #expect(WorkspaceAttentionCuePresentation.resolve(for: workspace, actionMenuOpen: true) == .suppressed)
        }
    }

    @Test func switchingWorkspaceRestoresOnlyStillApplicableRows() {
        // The launcher closes on a workspace switch. Opening the workspace
        // clears its unread flag server-side (workspace.markSeen), so its row
        // returns resting; another still-unread row returns raised.
        let opened = Self.workspace(attention: nil, id: "opened")
        let other = Self.workspace(attention: "unread", id: "other")
        #expect(WorkspaceAttentionCuePresentation.resolve(for: opened, actionMenuOpen: false) == .resting)
        #expect(WorkspaceAttentionCuePresentation.resolve(for: other, actionMenuOpen: false) == .raised)
    }

    // MARK: - Action cards come forward

    @Test func actionCardsSitInFrontOfEveryRaisedRow() throws {
        // The row lift constant is visionOS-only; read it from source.
        let layout = try Self.source("Intent/DesignSystem/Layout.swift")
        let declaration = try #require(layout.components(separatedBy: "static let attentionCueZOffset: CGFloat = ").dropFirst().first)
        let rowLift = try #require(Double(declaration.prefix { $0.isNumber || $0 == "." }))
        #expect(Double(WorkspaceActionMenuDepth.tileZOffset) > rowLift)
    }

    @Test func actionCardDepthStaysRestrained() {
        // HIG spatial layout: modest, comfortable depth, not a pop-out.
        #expect(WorkspaceActionMenuDepth.tileZOffset <= 32)
    }

    @Test func reduceTransparencySwapsGlassForAnOpaqueCard() {
        #expect(WorkspaceActionMenuDepth.usesGlass(reduceTransparency: false))
        #expect(!WorkspaceActionMenuDepth.usesGlass(reduceTransparency: true))
    }

    // MARK: - The open menu covers the floating composer (hosted)

    @Test func openMenuCoversTheWindowChatComposerAndDismissalRestoresIt() async throws {
        let coverage = ComposerCoverage()
        let state = MenuState()
        let host = try Host(MenuFixture(state: state, coverage: coverage))
        defer { host.tearDown() }

        try await Self.waitUntil("fixture mounted") { state.didAppear }
        #expect(coverage.isForemost(depth: 0), "a closed menu covers nothing")

        state.isOpen = true
        try await Self.waitUntil("open menu covers the chat") { !coverage.isForemost(depth: 0) }
        let covered = FloatingComposerPolicy.presentation(
            isActiveChat: true,
            isForemost: coverage.isForemost(depth: 0),
            showsLoadingState: false,
            composerVisible: true
        )
        #expect(covered == .covered, "the composer hides (unmounted: no input, focus or accessibility)")
        #expect(!FloatingComposerPolicy.cancelsPhotoImport(from: .shown, to: covered), "opening the menu must not drop an in-flight import")

        state.isOpen = false
        try await Self.waitUntil("dismissal restores the composer") { coverage.isForemost(depth: 0) }
        #expect(!FloatingComposerPolicy.cancelsPhotoImport(from: covered, to: .shown))

        for _ in 0..<3 {
            state.isOpen.toggle()
            try await Self.waitUntil("toggle settles") { coverage.isForemost(depth: 0) == !state.isOpen }
        }
    }

    @Test func menuCoverageKeepsAnImportInFlightAndRestoresAttachment() async throws {
        let coverage = ComposerCoverage()
        let state = MenuState()
        let pipeline = ConversationAttachmentPipeline()
        let (gate, release) = AsyncStream.makeStream(of: Void.self)
        defer { release.finish() }
        let image = try #require(UIImage(systemName: "photo")?.pngData())
        pipeline.loadPhotoData = { _ in
            for await _ in gate { break }
            return image
        }
        pipeline.selectedPhotoItems = [PhotosPickerItem(itemIdentifier: "menu-import")]
        pipeline.startLoadingSelectedPhotos(workspaceId: "demo-ws-dashboard")
        let importTask = try #require(pipeline.photoImportTask)
        let host = try Host(MenuFixture(state: state, coverage: coverage))
        defer { host.tearDown() }
        try await Self.waitUntil("fixture and import started") { state.didAppear && pipeline.isLoadingPhotos }

        state.isOpen = true
        try await Self.waitUntil("menu coverage registered") { !coverage.isForemost(depth: 0) }
        let presentation = FloatingComposerPolicy.presentation(
            isActiveChat: true,
            isForemost: coverage.isForemost(depth: 0),
            showsLoadingState: false,
            composerVisible: true
        )
        if FloatingComposerPolicy.cancelsPhotoImport(from: .shown, to: presentation) {
            pipeline.cancelPhotoImport()
        }
        release.yield()
        release.finish()
        await importTask.value
        #expect(pipeline.pendingImages.count == 1)
        state.isOpen = false
        try await Self.waitUntil("menu dismissed") { coverage.isForemost(depth: 0) }
        #expect(pipeline.pendingImages.count == 1)
    }

    @Test func menuTornDownWhileOpenReleasesItsCoverage() async throws {
        let coverage = ComposerCoverage()
        let state = MenuState()
        state.isOpen = true
        let host = try Host(MenuFixture(state: state, coverage: coverage))
        defer { host.tearDown() }

        try await Self.waitUntil("open menu covers the chat") { !coverage.isForemost(depth: 0) }
        state.isMounted = false
        try await Self.waitUntil("unmounting releases coverage") { coverage.isForemost(depth: 0) }
    }

    // MARK: - Source wiring

    @Test func launcherSharesItsOpenStateWithRowsAndTheComposer() throws {
        let launcher = try Self.source("Intent/Views/Workspaces/WorkspaceActionLauncher.swift")
        #expect(launcher.contains(".environment(\\.workspaceActionMenuOpen, isOpen)"))
        #expect(launcher.contains(".coversConversationComposers(while: isOpen)"))
    }

    @Test func rowsResolveTheirCueAgainstTheOpenMenu() throws {
        let row = try Self.source("Intent/Views/Workspaces/WorkspaceRowView.swift")
        #expect(row.contains("@Environment(\\.workspaceActionMenuOpen) private var actionMenuOpen"))
        #expect(row.contains(".visionAttentionCue(WorkspaceAttentionCuePresentation.resolve(for: workspace, actionMenuOpen: actionMenuOpen), reduceMotion: reduceMotion)"))
    }

    @Test func visionOSCueHidesSuppressedRowsCompletely() throws {
        let cue = try Self.source("Intent/Views/Workspaces/WorkspaceAttentionCue.swift")
        let helper = try #require(cue.components(separatedBy: "func visionAttentionCue(_ presentation: WorkspaceAttentionCuePresentation, reduceMotion: Bool)").dropFirst().first)
            .components(separatedBy: "func visionAttentionChipBrightness")[0]
        let visionGuard = "#if os(" + "visionOS)"
        let vision = try #require(helper.components(separatedBy: visionGuard).dropFirst().first)
            .components(separatedBy: "#else")[0]
        #expect(vision.contains(".opacity(presentation.isHidden ? 0 : 1)"))
        #expect(vision.contains(".allowsHitTesting(!presentation.isHidden)"))
        #expect(vision.contains(".accessibilityHidden(presentation.isHidden)"))
        #expect(vision.contains(".animation(nil, value: presentation.isHidden)"), "suppression cannot inherit the menu spring")
        #expect(vision.contains("reduceMotion ? nil : .easeOut"), "restored rows respect Reduce Motion")
        #expect(vision.contains(".offset(z: presentation.liftsTowardViewer"))
        let fallback = try #require(helper.components(separatedBy: "#else").dropFirst().first)
            .components(separatedBy: "#endif")[0]
        #expect(fallback.trimmingCharacters(in: .whitespacesAndNewlines) == "self", "iPhone/iPad rows are unchanged")
    }

    @Test func actionCardsUseNativeGlassDepthAndGazeOnlyOnVisionOS() throws {
        let tiles = try Self.source("Intent/Views/Workspaces/HomeActionTiles.swift")
        let launcher = try Self.source("Intent/Views/Workspaces/WorkspaceActionLauncher.swift")
        #expect(launcher.contains(".visionActionMenuDepth()"), "the open menu presents its cards forward")
        #expect(tiles.contains(".homeActionTileSurface(cornerRadius: Layout.cornerRadius, fill: Constants.WorkspaceList.controlSurface(for: colorScheme))"))
        let depth = try Self.source("Intent/Views/Workspaces/WorkspaceActionMenuDepth.swift")
        let visionGuard = "#if os(" + "visionOS)"
        let surface = try #require(depth.components(separatedBy: "func homeActionTileSurface(").dropFirst().first)
            .components(separatedBy: "func visionActionMenuDepth(")[0]
        let vision = try #require(surface.components(separatedBy: visionGuard).dropFirst().first)
            .components(separatedBy: "#else")[0]
        #expect(vision.contains("VisionActionTileSurface(shape: shape, fill: fill)"))
        let visionSurface = try #require(depth.components(separatedBy: "private struct VisionActionTileSurface: ViewModifier {").dropFirst().first)
        #expect(visionSurface.contains("WorkspaceActionMenuDepth.usesGlass(reduceTransparency: reduceTransparency)"))
        #expect(visionSurface.contains(".glassBackgroundEffect(in: shape)"))
        #expect(visionSurface.contains(".hoverEffect(.highlight)"))
        let fallback = try #require(surface.components(separatedBy: "#else").dropFirst().first)
            .components(separatedBy: "#endif")[0]
        #expect(fallback.contains("self.background(fill, in: shape)"), "iPhone/iPad keep the solid control surface")
        let lift = try #require(depth.components(separatedBy: "func visionActionMenuDepth(").dropFirst().first)
        let liftVision = try #require(lift.components(separatedBy: visionGuard).dropFirst().first)
            .components(separatedBy: "#else")[0]
        #expect(liftVision.contains(".offset(z: WorkspaceActionMenuDepth.tileZOffset)"))
    }

    // MARK: - Fixtures

    @Observable final class MenuState {
        var isOpen = false
        var isMounted = true
        var didAppear = false
    }

    private struct MenuFixture: View {
        let state: MenuState
        let coverage: ComposerCoverage

        var body: some View {
            ZStack {
                if state.isMounted {
                    Color.clear
                        .coversConversationComposers(while: state.isOpen)
                        .onAppear { state.didAppear = true }
                }
            }
            .environment(coverage)
        }
    }

    @MainActor
    private final class Host {
        private var window: UIWindow?
        private let previousKey: UIWindow?

        init(_ root: some View) throws {
            let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            previousKey = scene.keyWindow
            let window = UIWindow(windowScene: scene)
            window.rootViewController = UIHostingController(rootView: root)
            window.makeKeyAndVisible()
            self.window = window
        }

        func tearDown() {
            window?.isHidden = true
            window?.rootViewController = nil
            window = nil
            previousKey?.makeKey()
        }
    }

    private static func waitUntil(
        _ what: String,
        timeout: TimeInterval = 5,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline {
                Issue.record("timed out waiting for \(what)")
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private static func workspace(attention: String?, id: String = "ws", displayStatus: String? = nil) -> Workspace {
        Workspace(
            id: id,
            title: "Test",
            branch: nil,
            baseRef: nil,
            status: nil,
            activity: nil,
            displayStatus: displayStatus,
            attention: attention,
            lastActivity: nil,
            updatedAt: nil,
            repositoryOwner: nil,
            repositoryName: nil,
            prStatus: nil,
            prNumber: nil,
            diffSummaryTotalFiles: nil,
            taskStatsTotal: nil,
            taskStatsCompleted: nil,
            taskStatsInProgress: nil,
            agentSummaryCount: nil
        )
    }

    private static func source(_ relativePath: String) throws -> String {
        try String(contentsOf: TestSourceInputs.url(for: relativePath), encoding: .utf8)
    }
}
