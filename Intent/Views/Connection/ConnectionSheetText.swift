import CoreText
import SwiftUI

/// Figma measures from cap top to last baseline. Keep the full native glyphs
/// (including descenders) and wrapping, but measure spacing at those same edges.
struct ConnectionSheetText: View {
    let text: LocalizedStringKey
    let style: Constants.Typography.Style
    var tracking: CGFloat = 0
    @ScaledMetric private var capHeight: CGFloat

    init(_ text: LocalizedStringKey, style: Constants.Typography.Style, tracking: CGFloat = 0) {
        self.text = text
        self.style = style
        self.tracking = tracking
        let font = CTFontCreateWithName(style.face.rawValue as CFString, style.size, nil)
        _capHeight = ScaledMetric(wrappedValue: CTFontGetCapHeight(font), relativeTo: style.relativeTo)
    }

    var body: some View {
        CapHeightLayout(capHeight: capHeight) {
            Text(text)
                .interFont(style)
                .tracking(tracking)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct CapHeightLayout: Layout {
    let capHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        guard let text = subviews.first else { return .zero }
        let dimensions = text.dimensions(in: ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(
            width: dimensions.width,
            height: dimensions[.lastTextBaseline] - dimensions[.firstTextBaseline] + capHeight
        )
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        guard let text = subviews.first else { return }
        let proposal = ProposedViewSize(width: bounds.width, height: nil)
        let baseline = text.dimensions(in: proposal)[.firstTextBaseline]
        text.place(at: CGPoint(x: bounds.minX, y: bounds.minY + capHeight - baseline), proposal: proposal)
    }
}
