import CoreGraphics
import Foundation
@testable import Intent
import Testing

/// The visionOS floating composer (`FloatingComposerPolicy`): one ornament
/// composer per active chat, sized from the chat column, with the inline iOS
/// composer rules left untouched.
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
        #expect(FloatingComposerPolicy.isPresented(isActiveChat: true, showsLoadingState: false, composerVisible: true))
    }

    @Test func withdrawsWhileTheChatIsCovered() {
        // A pushed child agent owns the window's composer; the covered chat
        // must not leave a second ornament behind.
        #expect(!FloatingComposerPolicy.isPresented(isActiveChat: false, showsLoadingState: false, composerVisible: true))
    }

    @Test func hidesWhileTheTranscriptIsLoading() {
        #expect(!FloatingComposerPolicy.isPresented(isActiveChat: true, showsLoadingState: true, composerVisible: true))
    }

    @Test func hidesWhenTheQuestionSlotOwnsTheComposer() {
        // Pending-question recovery keeps the composer closed (fail closed).
        #expect(!FloatingComposerPolicy.isPresented(isActiveChat: true, showsLoadingState: false, composerVisible: false))
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
        #expect(ornament.contains("FloatingComposerPolicy.isPresented("))
        #expect(ornament.contains("FloatingComposerPolicy.width(forColumnWidth: columnWidth)"))
    }

    private static func source(_ relativePath: String) throws -> String {
        try String(contentsOf: TestSourceInputs.url(for: relativePath), encoding: .utf8)
    }
}
