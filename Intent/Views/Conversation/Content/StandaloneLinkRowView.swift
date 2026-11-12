import SwiftUI
import Textual

/// A chat line that is only one link, drawn as a full-width row at least
/// 44 pt tall so a tap anywhere on it opens the link, not just on the glyphs.
/// Opens through the environment's `openURL`, the same route as inline links.
struct StandaloneLinkRowView: View {
    let row: StandaloneLinkRow
    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .body) private var iconSide: CGFloat = 14

    private enum Layout {
        static let minimumHeight: CGFloat = 44
        static let spacing: CGFloat = 8
        static let verticalPadding: CGFloat = 6
        /// Spacing collapses to the larger neighbor value: rows stay close
        /// together, and the row's own padding plus this matches the gap
        /// before a following paragraph to the paragraph spacing.
        static let bottomBlockSpacing: CGFloat = 6
        static let iconOpacity = 0.75
        static let pressedOpacity = 0.08
        static let pressedCornerRadius: CGFloat = 8
        static let pressedOutset: CGFloat = -6
    }

    var body: some View {
        // Overflow excludes the row from Textual's selection overlay, which
        // would otherwise take every tap and open only the glyph run.
        Overflow { overflow in
            button
                .frame(width: overflow.containerWidth)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .textual.textSelection(.disabled)
        .textual.blockSpacing(.init(top: 0, bottom: Layout.bottomBlockSpacing))
    }

    private var button: some View {
        Button {
            openURL(row.url)
        } label: {
            HStack(spacing: Layout.spacing) {
                Text(row.title)
                    .underline()
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(row.opensFile ? .file : .chevronRight)
                    .resizable()
                    .scaledToFit()
                    .frame(width: iconSide, height: iconSide)
                    .opacity(Layout.iconOpacity)
                    .accessibilityHidden(true)
            }
            .foregroundStyle(Constants.Colors.Markdown.linkForeground(for: colorScheme))
            .padding(.vertical, Layout.verticalPadding)
            .frame(maxWidth: .infinity, minHeight: Layout.minimumHeight, alignment: .leading)
            .contentShape(Rectangle())
            .copyContextMenuPassthrough()
        }
        .buttonStyle(PressHighlightStyle(colorScheme: colorScheme))
        .accessibilityRemoveTraits(.isButton)
        .accessibilityAddTraits(.isLink)
        .accessibilityIdentifier("markdown.linkRow")
    }

    private struct PressHighlightStyle: ButtonStyle {
        let colorScheme: ColorScheme

        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .background {
                    if configuration.isPressed {
                        RoundedRectangle(cornerRadius: Layout.pressedCornerRadius)
                            .fill(Constants.Colors.Markdown.linkForeground(for: colorScheme).opacity(Layout.pressedOpacity))
                            .padding(.horizontal, Layout.pressedOutset)
                    }
                }
        }
    }
}
