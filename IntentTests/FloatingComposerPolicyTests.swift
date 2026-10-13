import CoreGraphics
import Foundation
@testable import Intent
import Testing

/// The visionOS floating composer (`FloatingComposerPolicy`): one ornament
/// composer per active chat, sized from the chat column, with the inline iOS
/// composer rules left untouched.
@MainActor
struct FloatingComposerPolicyTests {
    // MARK: - Host selection

    @Test func visionOSFloatsTheComposer() {
        #expect(ComposerHost.forPlatform(isVisionOS: true) == .floatingOrnament)
    }

    @Test func iOSKeepsTheInlineComposer() {
        #expect(ComposerHost.forPlatform(isVisionOS: false) == .inline)
    }

    // MARK: - Presentation

    @Test func presentsForTheActiveLoadedChat() {
        #expect(FloatingComposerPolicy.presentation(isActiveChat: true, isForemost: true, showsLoadingState: false, composerVisible: true) == .shown)
    }

    @Test func withdrawsWhileTheChatIsCovered() {
        // A pushed child agent owns the window's composer; the covered chat
        // must not leave a second ornament behind.
        #expect(FloatingComposerPolicy.presentation(isActiveChat: false, isForemost: true, showsLoadingState: false, composerVisible: true) == .withdrawn)
    }

    @Test func withdrawsWhileAModalCoversTheChat() {
        // Regression: the Assistant sheet over an open chat left the covered
        // chat's composer on screen (two composers, covered draft sendable).
        let presentation = FloatingComposerPolicy.presentation(isActiveChat: true, isForemost: false, showsLoadingState: false, composerVisible: true)
        #expect(presentation == .covered)
        #expect(!presentation.revealsComposer)
    }

    @Test func hidesWhileTheTranscriptIsLoading() {
        #expect(FloatingComposerPolicy.presentation(isActiveChat: true, isForemost: true, showsLoadingState: true, composerVisible: true) == .withdrawn)
    }

    @Test func hidesWhenTheQuestionSlotOwnsTheComposer() {
        // Pending-question recovery keeps the composer closed (fail closed).
        #expect(FloatingComposerPolicy.presentation(isActiveChat: true, isForemost: true, showsLoadingState: false, composerVisible: false) == .withdrawn)
    }

    // MARK: - Modal coverage (ComposerCoverage)

    @Test func windowChatIsForemostWithNoModalOpen() {
        #expect(ComposerCoverage().isForemost(depth: 0))
    }

    @Test func sheetCoversTheWindowChatButNotItsOwnChat() {
        // Assistant sheet (layer 1) over a window chat (depth 0): only the
        // sheet's chat keeps a composer.
        let coverage = ComposerCoverage()
        coverage.cover(UUID(), depth: 1)
        #expect(!coverage.isForemost(depth: 0))
        #expect(coverage.isForemost(depth: 1))
    }

    @Test func dismissingTheSheetRestoresTheWindowChat() {
        let coverage = ComposerCoverage()
        let sheet = UUID()
        coverage.cover(sheet, depth: 1)
        coverage.uncover(sheet)
        #expect(coverage.isForemost(depth: 0))
    }

    @Test func nestedModalCoversEveryChatBeneathIt() {
        // A lightbox (layer 2) opened from the Assistant chat (depth 1).
        let coverage = ComposerCoverage()
        let sheet = UUID()
        let lightbox = UUID()
        coverage.cover(sheet, depth: 1)
        coverage.cover(lightbox, depth: 2)
        #expect(!coverage.isForemost(depth: 0))
        #expect(!coverage.isForemost(depth: 1))
        coverage.uncover(lightbox)
        #expect(coverage.isForemost(depth: 1))
        #expect(!coverage.isForemost(depth: 0))
    }

    @Test func uncoveringAnUnknownLayerIsHarmless() {
        let coverage = ComposerCoverage()
        coverage.cover(UUID(), depth: 1)
        coverage.uncover(UUID())
        #expect(!coverage.isForemost(depth: 0))
    }

    // MARK: - Width follows the window

    @Test func unmeasuredColumnUsesIdealWidth() {
        #expect(FloatingComposerPolicy.width(forColumnWidth: 0) == nil)
        #expect(FloatingComposerPolicy.width(forColumnWidth: -10) == nil)
    }

    @Test func tracksColumnWidthInsideMargins() {
        let column: CGFloat = 600
        #expect(FloatingComposerPolicy.width(forColumnWidth: column) == column - FloatingComposerPolicy.horizontalMargin * 2)
    }

    @Test func resizingTheWindowResizesTheComposer() throws {
        let narrow = try #require(FloatingComposerPolicy.width(forColumnWidth: 500))
        let wide = try #require(FloatingComposerPolicy.width(forColumnWidth: 700))
        #expect(wide > narrow)
    }

    @Test func capsAtTheMaximumOnWideWindows() {
        #expect(FloatingComposerPolicy.width(forColumnWidth: 2400) == FloatingComposerPolicy.maximumWidth)
    }

    @Test func keepsAMinimumWidthOnNarrowColumns() {
        let column = FloatingComposerPolicy.minimumWidth + FloatingComposerPolicy.horizontalMargin
        #expect(FloatingComposerPolicy.width(forColumnWidth: column) == FloatingComposerPolicy.minimumWidth)
    }

    @Test func neverExceedsAColumnNarrowerThanTheMinimum() {
        let column = FloatingComposerPolicy.minimumWidth - 40
        #expect(FloatingComposerPolicy.width(forColumnWidth: column) == column)
    }

    // MARK: - Launcher avoidance

    @Test func inlineHostReportsQuestionTopOnlyWhenItReplacesTheComposer() {
        // Prior iOS rule, unchanged: the composer reports its own top.
        let replaced = FloatingComposerPolicy.questionRegionLauncherTop(
            host: .inline,
            questionInputTop: 500,
            hasQuestionContent: true,
            composerVisible: false,
            usesPhoneQuestionPresentation: false
        )
        let composerShown = FloatingComposerPolicy.questionRegionLauncherTop(
            host: .inline,
            questionInputTop: 500,
            hasQuestionContent: true,
            composerVisible: true,
            usesPhoneQuestionPresentation: false
        )
        let phone = FloatingComposerPolicy.questionRegionLauncherTop(
            host: .inline,
            questionInputTop: 500,
            hasQuestionContent: true,
            composerVisible: false,
            usesPhoneQuestionPresentation: true
        )
        #expect(replaced == 500)
        #expect(composerShown == nil)
        #expect(phone == nil)
    }

    @Test func floatingHostKeepsTheLauncherAboveTheQuestionBanner() {
        // The composer is outside the window, so the in-window question
        // banner is the input the launcher must avoid even while the
        // composer is shown.
        let top = FloatingComposerPolicy.questionRegionLauncherTop(
            host: .floatingOrnament,
            questionInputTop: 640,
            hasQuestionContent: true,
            composerVisible: true,
            usesPhoneQuestionPresentation: false
        )
        #expect(top == 640)
    }

    @Test func floatingHostIgnoresAStaleTopFromAnEmptyQuestionRegion() {
        let top = FloatingComposerPolicy.questionRegionLauncherTop(
            host: .floatingOrnament,
            questionInputTop: 640,
            hasQuestionContent: false,
            composerVisible: true,
            usesPhoneQuestionPresentation: false
        )
        #expect(top == nil)
    }

    @Test func floatingHostKeepsTheLauncherAboveStatusRows() {
        // Regression: with the composer outside the window, waiting/monitor/
        // hook/queue rows sit at the window bottom under the launcher. The
        // launcher must rise above the topmost of them (and the question
        // banner beneath them).
        let top = FloatingComposerPolicy.questionRegionLauncherTop(
            host: .floatingOrnament,
            questionInputTop: 640,
            hasQuestionContent: true,
            composerVisible: true,
            usesPhoneQuestionPresentation: false,
            accessoryRowsTop: 580
        )
        let rowsOnly = FloatingComposerPolicy.questionRegionLauncherTop(
            host: .floatingOrnament,
            questionInputTop: 640,
            hasQuestionContent: false,
            composerVisible: true,
            usesPhoneQuestionPresentation: false,
            accessoryRowsTop: 600
        )
        #expect(top == 580)
        #expect(rowsOnly == 600)
    }

    @Test func inlineHostIgnoresStatusRowsForTheLauncher() {
        // iPhone/iPad: the inline composer still reports its own top.
        let top = FloatingComposerPolicy.questionRegionLauncherTop(
            host: .inline,
            questionInputTop: 640,
            hasQuestionContent: true,
            composerVisible: true,
            usesPhoneQuestionPresentation: false,
            accessoryRowsTop: 580
        )
        #expect(top == nil)
    }

    @Test func floatingHostReservesTranscriptRoomForTheLauncher() {
        // Regression: the bottom-right launcher covered the last transcript
        // line once the composer left the window.
        let clearance = AssistantLaunchButton.scrollClearance
        #expect(FloatingComposerPolicy.transcriptBottomClearance(host: .floatingOrnament, launcherClearance: clearance) == clearance)
    }

    @Test func transcriptClearanceOnlyWhereALauncherFloatsOverAFloatingHost() {
        // No launcher above this chat (Assistant sheet, search open): no gap.
        #expect(FloatingComposerPolicy.transcriptBottomClearance(host: .floatingOrnament, launcherClearance: 0) == 0)
        // iPhone/iPad keep the transcript unchanged.
        #expect(FloatingComposerPolicy.transcriptBottomClearance(host: .inline, launcherClearance: AssistantLaunchButton.scrollClearance) == 0)
    }

    @Test func launcherClearanceReachesTheTranscript() throws {
        let launcher = try Self.source("Intent/Views/Workspaces/WorkspaceActionLauncher.swift")
        let column = try Self.source("Intent/Views/Conversation/Transcript/ConversationColumnView.swift")
        let transcript = try Self.source("Intent/Views/Conversation/Transcript/ConversationTranscriptView+Presentation.swift")
        #expect(launcher.contains(".environment(\\.workspaceActionLauncherClearance, isSearching ? 0 : AssistantLaunchButton.scrollClearance)"))
        #expect(column.contains("@Environment(\\.workspaceActionLauncherClearance) private var launcherClearance"))
        #expect(column.contains("bottomClearance: FloatingComposerPolicy.transcriptBottomClearance(host: composerHost, launcherClearance: launcherClearance)"))
        #expect(column.contains("accessoryRowsTop: accessoryRowsLauncherTop"))
        // On the end marker, so follow landings still reach the true end.
        #expect(transcript.components(separatedBy: ".padding(.bottom, Layout.bottomAnchorPadding + bottomClearance)").count - 1 == 2)
    }

    // MARK: - Source wiring (visionOS branches cannot run in the iOS test host)

    @Test func visionOSColumnHostsOneComposerInAGlassOrnament() throws {
        let column = try Self.source("Intent/Views/Conversation/Transcript/ConversationColumnView.swift")
        let ornament = try Self.source("Intent/Views/Conversation/Composer/FloatingComposerOrnament.swift")
        // Exactly two construction sites: the inline host (gated off on
        // visionOS) and the floating ornament host.
        #expect(column.components(separatedBy: "MessageInputView(").count - 1 == 2)
        #expect(column.contains("if composerHost == .inline, !viewModel.showsLoadingState"))
        #expect(column.contains(".modifier(FloatingComposerOrnament("))
        #expect(ornament.contains(".ornament("))
        #expect(ornament.contains(".glassBackgroundEffect(in: shape)"))
        #expect(ornament.contains("FloatingComposerPolicy.presentation("))
        #expect(ornament.contains("coverage?.isForemost(depth: layerDepth)"))
        #expect(ornament.contains("FloatingComposerPolicy.cancelsPhotoImport(from: old, to: new)"))
        #expect(column.contains("onWithdraw: viewModel.cancelPhotoImport"))
        #expect(ornament.contains("FloatingComposerPolicy.width(forColumnWidth: columnWidth)"))
    }

    /// Regression (Assistant sheet over an open chat showed two floating
    /// composers, and the covered draft could still be sent): every modal
    /// that can open over a chat on visionOS must register as a covering
    /// layer, so only the foremost chat keeps its composer.
    @Test(arguments: [
        "Intent/App/RootView.swift",
        "Intent/Views/Conversation/Transcript/ConversationView.swift",
        "Intent/Views/Conversation/Transcript/ConversationColumnView.swift",
        "Intent/Views/Conversation/Content/MarkdownTextView.swift",
        "Intent/Views/Conversation/Content/ContentBlockView.swift",
        "Intent/Views/Conversation/Content/AttachmentReferenceImageView.swift",
        "Intent/Views/Conversation/Content/AttachmentReferenceVideoView.swift",
        "Intent/Views/Conversation/Content/ImageAttachmentThumbnail.swift",
        "Intent/Views/Conversation/Content/MermaidDiagramView.swift"
    ])
    func chatCoveringModalsSuppressComposersBeneath(_ path: String) throws {
        let source = try Self.source(path)
        let presentations = source.components(separatedBy: ".sheet(").count - 1
            + source.components(separatedBy: ".fullScreenCover(").count - 1
        let coveringLayers = source.components(separatedBy: ".coversConversationComposers()").count - 1
        #expect(presentations > 0, "\(path) no longer presents a modal; update this list")
        #expect(
            coveringLayers == presentations,
            "\(path): \(presentations) modal presentation(s) but \(coveringLayers) covering layer(s)"
        )
    }

    private static func source(_ relativePath: String) throws -> String {
        try String(contentsOf: TestSourceInputs.url(for: relativePath), encoding: .utf8)
    }
}
