import SwiftUI

/// Figma anchors adapted to this window's safe-area width and text size.
struct IPadShellLayout: Equatable {
    static let railWidth: CGFloat = 48
    static let iconSize: CGFloat = 24
    static let railSpacing: CGFloat = 8
    static let railTopInset: CGFloat = 32
    static let cornerRadius: CGFloat = 20
    static let largeWindowWidth: CGFloat = 1300
    static let compactWindowWidth: CGFloat = 600
    static let largeInset: CGFloat = 24
    static let smallInset: CGFloat = 16
    static let largeSidebarWidth: CGFloat = 400
    static let smallSidebarWidth: CGFloat = 384
    static let minimumDetailWidth: CGFloat = 480
    static let accessibleDetailWidth: CGFloat = 560
    static let shadowOpacity = 0.04
    static let shadowRadius: CGFloat = 24
    static let shadowOffset: CGFloat = 16
    static let drawerShadeOpacity = 0.2

    let width: CGFloat
    let isAccessibilitySize: Bool

    var usesCompactNavigation: Bool { width < Self.compactWindowWidth }
    var inset: CGFloat { width >= Self.largeWindowWidth ? Self.largeInset : Self.smallInset }
    var gutter: CGFloat { inset }
    var railGutter: CGFloat { usesCompactNavigation ? 0 : gutter }
    var preferredSidebarWidth: CGFloat {
        width >= Self.largeWindowWidth ? Self.largeSidebarWidth : Self.smallSidebarWidth
    }
    var contentWidth: CGFloat { max(0, width - 2 * inset - (usesCompactNavigation ? 0 : Self.railWidth + railGutter)) }
    var sidebarWidth: CGFloat { usesCompactNavigation ? contentWidth : min(preferredSidebarWidth, contentWidth) }
    var usesSidebarOverlay: Bool {
        let minimumDetail = isAccessibilitySize ? Self.accessibleDetailWidth : Self.minimumDetailWidth
        return contentWidth < preferredSidebarWidth + gutter + minimumDetail
    }

    func detailLeadingInset(sidebarVisible: Bool) -> CGFloat {
        sidebarVisible && !usesSidebarOverlay ? sidebarWidth + gutter : 0
    }
}
