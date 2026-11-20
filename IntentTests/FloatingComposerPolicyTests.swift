import CoreGraphics
import Foundation
@testable import Intent
import Testing

@MainActor
struct FloatingComposerPolicyTests {
    @Test func visionOSFloatsTheComposer() {
        #expect(ComposerHost.forPlatform(isVisionOS: true) == .floatingOrnament)
    }

    @Test func iOSKeepsTheInlineComposer() {
        #expect(ComposerHost.forPlatform(isVisionOS: false) == .inline)
    }

    @Test func presentsForTheActiveLoadedChat() {
        #expect(FloatingComposerPolicy.presentation(isActiveChat: true, isForemost: true, showsLoadingState: false, composerVisible: true) == .shown)
    }

    @Test func withdrawsWhileTheChatIsCovered() {
        #expect(FloatingComposerPolicy.presentation(isActiveChat: false, isForemost: true, showsLoadingState: false, composerVisible: true) == .withdrawn)
    }

    @Test func withdrawsWhileAModalCoversTheChat() {
        let presentation = FloatingComposerPolicy.presentation(isActiveChat: true, isForemost: false, showsLoadingState: false, composerVisible: true)
        #expect(presentation == .covered)
        #expect(!presentation.revealsComposer)
    }

    @Test func hidesWhileTheTranscriptIsLoading() {
        #expect(FloatingComposerPolicy.presentation(isActiveChat: true, isForemost: true, showsLoadingState: true, composerVisible: true) == .withdrawn)
    }

    @Test func hidesWhenTheQuestionSlotOwnsTheComposer() {
        #expect(FloatingComposerPolicy.presentation(isActiveChat: true, isForemost: true, showsLoadingState: false, composerVisible: false) == .withdrawn)
    }

    @Test func windowChatIsForemostWithNoModalOpen() {
        #expect(ComposerCoverage().isForemost(depth: 0))
    }

    @Test func sheetCoversTheWindowChatButNotItsOwnChat() {
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

    @Test func inlineHostReportsQuestionTopOnlyWhenItReplacesTheComposer() {
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

    @Test func transcriptKeepsNoLauncherPaddingUnderTheLastRow() throws {
        let launcher = try Self.source("Intent/Views/Workspaces/WorkspaceActionLauncher.swift")
        let column = try Self.source("Intent/Views/Conversation/Transcript/ConversationColumnView.swift")
        let transcript = try Self.source("Intent/Views/Conversation/Transcript/ConversationTranscriptView+Presentation.swift")
        #expect(!launcher.contains("LauncherClearance"))
        #expect(!column.contains("launcherClearance"))
        #expect(!column.contains("bottomClearance"))
        #expect(column.contains("accessoryRowsTop: accessoryRowsLauncherTop"))
        #expect(transcript.components(separatedBy: ".padding(.bottom, Layout.bottomAnchorPadding)").count - 1 == 2)
        #expect(!transcript.contains("bottomClearance"))
    }

    @Test func visionOSColumnHostsOneComposerInAGlassOrnament() throws {
        let column = try Self.source("Intent/Views/Conversation/Transcript/ConversationColumnView.swift")
        let ornament = try Self.source("Intent/Views/Conversation/Composer/FloatingComposerOrnament.swift")
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
