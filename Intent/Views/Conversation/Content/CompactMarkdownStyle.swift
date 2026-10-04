import SwiftUI
import Textual

/// Textual port of the app's previous compact markdown theme: same relative font
/// scales, weights, margins, and paddings, expressed as a `StructuredText.Style`.
struct CompactMarkdownStyle: StructuredText.Style {
    /// Inline-code colors from the old `.markdownTextStyle(\.code)` override.
    static let codeForeground = DynamicColor(
        light: Constants.Colors.Markdown.inlineCodeForeground(for: .light),
        dark: Constants.Colors.Markdown.inlineCodeForeground(for: .dark)
    )
    static let codeBackground = DynamicColor(
        light: Constants.Colors.Markdown.inlineCodeBackground(for: .light),
        dark: Constants.Colors.Markdown.inlineCodeBackground(for: .dark)
    )

    let inlineStyle = InlineStyle()
        .code(
            // Inter has no monospaced design; select the system code font explicitly.
            .font(.system(.body, design: .monospaced)),
            .fontScale(Constants.Markdown.codeFontScale),
            .foregroundColor(Self.codeForeground),
            .backgroundColor(Self.codeBackground)
        )
        .link(.foregroundColor(.blue))
    let headingStyle = CompactHeadingStyle()
    let paragraphStyle = CompactParagraphStyle()
    let blockQuoteStyle = CompactBlockQuoteStyle()
    let codeBlockStyle: MermaidCodeBlockStyle
    let listItemStyle: StructuredText.DefaultListItemStyle = .default
    let unorderedListMarker: StructuredText.HierarchicalSymbolListMarker = .hierarchical(
        .disc,
        .circle,
        .square
    )
    let orderedListMarker: StructuredText.DecimalListMarker = .decimal
    let tableStyle = CompactTableStyle()
    let tableCellStyle = CompactTableCellStyle()
    let thematicBreakStyle = CompactThematicBreakStyle()

    init(mermaidSources: [String: String] = [:], pendingMermaidLanguage: String? = nil) {
        codeBlockStyle = MermaidCodeBlockStyle(sources: mermaidSources, pendingLanguage: pendingMermaidLanguage)
    }
}

extension StructuredText.Style where Self == CompactMarkdownStyle {
    static var compact: Self { .init() }
}

/// Keep the compact heading ratios and margins, using the Inter body baseline
/// and real semibold/medium faces rather than changing the prose scaling role.
struct CompactHeadingStyle: StructuredText.HeadingStyle {
    private static let maximumHeadingLevel = 6
    private static let arrayIndexOffset = 1

    func makeBody(configuration: Configuration) -> some View {
        let level = min(configuration.headingLevel, Self.maximumHeadingLevel)
        configuration.label
            .textual.fontScale(Constants.Markdown.Heading.fontScales[level - Self.arrayIndexOffset])
            .interFont(Constants.Typography.bodyS.withFace(
                Constants.Markdown.Heading.weights[level - Self.arrayIndexOffset] == .semibold ? .semibold : .medium
            ))
            .textual.blockSpacing(.init(
                top: Constants.Markdown.Heading.topMargins[level - Self.arrayIndexOffset],
                bottom: Constants.Markdown.Heading.bottomMargin
            ))
    }
}

struct CompactParagraphStyle: StructuredText.ParagraphStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .fixedSize(horizontal: false, vertical: true)
            .textual.lineSpacing(.fontScaled(Constants.Markdown.lineSpacingScale))
            .textual.blockSpacing(.init(top: 0, bottom: Constants.Markdown.baseFontSize))
    }
}

struct CompactBlockQuoteStyle: StructuredText.BlockQuoteStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .italic()
            .textual.padding(.leading, .fontScaled(Constants.Markdown.BlockQuote.leadingPaddingScale))
            .textual.padding(.trailing, .fontScaled(Constants.Markdown.BlockQuote.trailingPaddingScale))
    }
}

/// The old `.markdownBlockStyle(\.codeBlock)` override: 12pt padding, muted
/// rounded box, monospaced 0.85em, no horizontal scroller.
struct CompactCodeBlockStyle: StructuredText.CodeBlockStyle {
    private static let background = DynamicColor(
        light: Constants.Colors.Markdown.codeBlockBackground(for: .light),
        dark: Constants.Colors.Markdown.codeBlockBackground(for: .dark)
    )

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .textual.lineSpacing(.fontScaled(Constants.Markdown.lineSpacingScale))
            .textual.fontScale(Constants.Markdown.codeFontScale)
            .fixedSize(horizontal: false, vertical: true)
            .font(.system(.body, design: .monospaced))
            .padding(Constants.Markdown.CodeBlock.contentPadding)
            .background(Self.background)
            .clipShape(RoundedRectangle(cornerRadius: Constants.Markdown.CodeBlock.cornerRadius))
            .textual.blockSpacing(.init(top: 0, bottom: Constants.Markdown.baseFontSize))
    }
}

struct MermaidCodeBlockStyle: StructuredText.CodeBlockStyle {
    let sources: [String: String]
    let pendingLanguage: String?

    @ViewBuilder
    func makeBody(configuration: Configuration) -> some View {
        if let language = configuration.languageHint, language == pendingLanguage {
            MermaidStreamingPlaceholder()
                .textual.blockSpacing(.init(top: 0, bottom: Constants.Markdown.baseFontSize))
        } else if let language = configuration.languageHint, let source = sources[language] {
            MermaidDiagramView(source: source)
                .textual.blockSpacing(.init(top: 0, bottom: Constants.Markdown.baseFontSize))
        } else {
            CompactCodeBlockStyle().makeBody(configuration: configuration)
        }
    }
}

/// Keep the GitHub grid decoration, but let columns size independently of the
/// transcript width. Textual's overflow container preserves selection gestures.
struct CompactTableStyle: StructuredText.TableStyle {
    func makeBody(configuration: Configuration) -> some View {
        Overflow {
            StructuredText.GitHubTableStyle()
                .makeBody(configuration: configuration)
                .fixedSize(horizontal: false, vertical: true)
        }
        .textual.blockSpacing(.init(top: 0, bottom: Constants.Markdown.Table.bottomMargin))
    }
}

/// Inter body cells, a semibold header row, and the existing 0.72em/0.35em padding.
struct CompactTableCellStyle: StructuredText.TableCellStyle {
    @ScaledMetric(relativeTo: .body) private var maximumWidth = Constants.Markdown.TableCell.maximumWidth

    func makeBody(configuration: Configuration) -> some View {
        CompactTableCellLayout(maximumWidth: maximumWidth) {
            configuration.label
                .interFont(Constants.Typography.bodyS.withFace(configuration.row == 0 ? .semibold : .regular))
                .textual.lineSpacing(.fontScaled(Constants.Markdown.lineSpacingScale))
        }
        .textual.padding(.horizontal, .fontScaled(Constants.Markdown.TableCell.horizontalPaddingScale))
        .textual.padding(.vertical, .fontScaled(Constants.Markdown.TableCell.verticalPaddingScale))
    }
}

/// Measure and place with the same width proposal: capping an already measured
/// ideal-width cell would leave its wrapped text taller than the grid row.
private struct CompactTableCellLayout: Layout {
    let maximumWidth: CGFloat

    func sizeThatFits(proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        subviews.first?.sizeThatFits(.init(width: maximumWidth, height: nil)) ?? .zero
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        subviews.first?.place(
            at: bounds.origin,
            anchor: .topLeading,
            proposal: .init(width: maximumWidth, height: nil)
        )
    }
}

struct CompactThematicBreakStyle: StructuredText.ThematicBreakStyle {
    func makeBody(configuration _: Configuration) -> some View {
        Divider()
            .textual.blockSpacing(
                .init(
                    top: Constants.Markdown.thematicBreakMarginScale * Constants.Markdown.baseFontSize,
                    bottom: Constants.Markdown.thematicBreakMarginScale * Constants.Markdown.baseFontSize
                )
            )
    }
}
