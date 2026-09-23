@testable import Intent
import SwiftUI
import Testing

/// Exercise the rendered consumers, not a second list of design-token values.
@MainActor
struct QuestionWizardRenderingTests {
    private enum Fixture {
        static let width: CGFloat = 700
        static let collapsedHeight: CGFloat = 44
        static let headerHeight: CGFloat = 54
        static let footerHeight: CGFloat = 58
        static let questionCount = 3
    }

    @Test(arguments: [false, true], [false, true])
    func normalRowsKeepTheirHeightAcrossAppearance(dark: Bool, increasedContrast: Bool) throws {
        let collapsed = try renderedSize(banner(), dark: dark, increasedContrast: increasedContrast)
        let expandedHeader = try renderedSize(header, dark: dark, increasedContrast: increasedContrast)
        let expandedFooter = try renderedSize(footer(), dark: dark, increasedContrast: increasedContrast)

        #expect(collapsed == CGSize(width: Fixture.width, height: Fixture.collapsedHeight))
        #expect(expandedHeader == CGSize(width: Fixture.width, height: Fixture.headerHeight))
        #expect(expandedFooter == CGSize(width: Fixture.width, height: Fixture.footerHeight))
    }

    @Test func accessibilityTextCanGrowTheCollapsedAndExpandedRows() throws {
        let collapsed = try renderedSize(banner(), textSize: .accessibility5)
        let expandedHeader = try renderedSize(header, textSize: .accessibility5)
        let expandedFooter = try renderedSize(footer(), textSize: .accessibility5)

        #expect(collapsed.height > Fixture.collapsedHeight)
        #expect(expandedHeader.height > Fixture.headerHeight)
        #expect(expandedFooter.height > Fixture.footerHeight)
    }

    @Test func disabledControlsKeepTheirLayout() throws {
        let enabledBanner = try renderedSize(banner())
        let disabledBanner = try renderedSize(banner(dismissed: true))
        let enabledFooter = try renderedSize(footer())
        let disabledFooter = try renderedSize(footer(disabled: true))

        #expect(disabledBanner == enabledBanner)
        #expect(disabledFooter == enabledFooter)
    }

    private func banner(dismissed: Bool = false) -> some View {
        QuestionWizardCollapsedBanner(
            questionCount: Fixture.questionCount,
            showsDismiss: true,
            dismissed: dismissed,
            onExpand: {},
            onDismiss: {}
        )
    }

    private var header: some View {
        QuestionWizardHeaderRow(
            questionCount: Fixture.questionCount,
            index: 1,
            isMulti: true,
            showsDismiss: true,
            dismissed: false,
            onIgnore: {},
            onDismiss: {}
        )
    }

    private func footer(disabled: Bool = false) -> some View {
        QuestionWizardFooterRow(
            index: 1,
            multiStep: true,
            isMulti: true,
            isLast: false,
            showNext: true,
            nextDisabled: disabled,
            submitted: false,
            dismissed: false,
            onBack: {},
            onSkip: {},
            onNext: {}
        )
    }

    private func renderedSize<Content: View>(
        _ content: Content,
        textSize: DynamicTypeSize = .large,
        dark: Bool = false,
        increasedContrast: Bool = false
    ) throws -> CGSize {
        // ImageRenderer needs the SDK's writable backing key; colorSchemeContrast is read-only.
        let styledContent = content
            .environment(\.dynamicTypeSize, textSize)
            .environment(\.colorScheme, dark ? .dark : .light)
            .environment(\._colorSchemeContrast, increasedContrast ? .increased : .standard)
            .environment(\.locale, Locale(identifier: "en_US"))
        let renderer = ImageRenderer(content: styledContent)
        renderer.scale = 1
        renderer.proposedSize = ProposedViewSize(width: Fixture.width, height: nil)
        let image = try #require(renderer.cgImage)
        return CGSize(width: image.width, height: image.height)
    }
}
