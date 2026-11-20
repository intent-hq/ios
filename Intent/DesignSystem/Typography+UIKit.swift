import SwiftUI
import UIKit

extension Constants.Typography.Style {
    nonisolated func uiFont(compatibleWith traits: UITraitCollection) -> UIFont {
        let resolvedFace = traits.legibilityWeight == .bold ? face.legibleFace : face
        let base = UIFont(name: resolvedFace.rawValue, size: size) ?? UIFont.systemFont(ofSize: size)
        return UIFontMetrics(forTextStyle: uiTextStyle).scaledFont(for: base, compatibleWith: traits)
    }

    nonisolated private var uiTextStyle: UIFont.TextStyle {
        switch relativeTo {
        case .largeTitle: .largeTitle
        case .title: .title1
        case .title2: .title2
        case .title3: .title3
        case .headline: .headline
        case .subheadline: .subheadline
        case .body: .body
        case .callout: .callout
        case .footnote: .footnote
        case .caption: .caption1
        case .caption2: .caption2
        @unknown default: .body
        }
    }
}
