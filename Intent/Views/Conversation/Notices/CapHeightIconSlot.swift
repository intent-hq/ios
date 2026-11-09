import CoreText
import SwiftUI

/// A slot as tall as a text style's cap height that centres its icon on it.
/// Bottom-aligned to a first text baseline (or top-aligned to a cap top), the
/// icon centres on that line's capitals and does not change the row height.
struct CapHeightIconSlot<Icon: View>: View {
    let style: Constants.Typography.Style
    let width: CGFloat
    let icon: Icon
    @ScaledMetric private var fontSize: CGFloat
    @Environment(\.legibilityWeight) private var legibilityWeight

    init(style: Constants.Typography.Style, width: CGFloat, @ViewBuilder icon: () -> Icon) {
        self.style = style
        self.width = width
        self.icon = icon()
        _fontSize = ScaledMetric(wrappedValue: style.size, relativeTo: style.relativeTo)
    }

    var body: some View {
        Color.clear
            .frame(width: width, height: capHeight)
            .overlay { icon }
            .accessibilityHidden(true)
    }

    private var capHeight: CGFloat {
        style.capHeight(size: fontSize, legibilityWeight: legibilityWeight)
    }
}

extension Constants.Typography.Style {
    /// Cap height at a scaled point size, using the face Bold Text renders.
    func capHeight(size: CGFloat, legibilityWeight: LegibilityWeight?) -> CGFloat {
        let face = legibilityWeight == .bold ? self.face.legibleFace : self.face
        return CTFontGetCapHeight(CTFontCreateWithName(face.rawValue as CFString, size, nil))
    }
}
