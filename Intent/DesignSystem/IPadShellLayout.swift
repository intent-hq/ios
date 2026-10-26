import SwiftUI

/// Figma anchors adapted to this window's safe-area width and text size.
struct IPadShellLayout: Equatable {
    static let focusLayer: Double = 3
    static let focusPanelWidth: CGFloat = 624
    static let focusContentInset: CGFloat = 32
    static let focusBlurRadius: CGFloat = 6
    static let focusShadeOpacity = 0.45
    static let railWidth: CGFloat = 48
    static let iconSize: CGFloat = 24
    static let railSpacing: CGFloat = 8
    static let headerInset: CGFloat = 24
    static let railTopInset = Self.headerInset
    static let contextualRailTopInset: CGFloat = 116
    static let leadingContextualRailTopInset: CGFloat = 56
    static let contextualRailOuterInset: CGFloat = 12
    static let contextualRailSpacing: CGFloat = 4
    static let cornerRadius: CGFloat = 20
    static let largeWindowWidth: CGFloat = 1300
    static let compactWindowWidth: CGFloat = 600
    static let outerInset: CGFloat = 16
    static let largeSidebarWidth: CGFloat = 400
    static let smallSidebarWidth: CGFloat = 384
    static let foldableSidebarDivisor: CGFloat = 3
    static let minimumDetailWidth: CGFloat = 480
    static let accessibleDetailWidth: CGFloat = 560
    static let shadowOpacity = 0.04
    static let shadowRadius: CGFloat = 24
    static let shadowOffset: CGFloat = 16
    static let drawerShadeOpacity = 0.2

    let width: CGFloat
    let isAccessibilitySize: Bool
    var usesFoldableLayout = false
    var usesLeadingVerticalBar = false

    static func contextualRailTopPadding(for edge: HorizontalEdge?) -> CGFloat {
        edge == .leading ? leadingContextualRailTopInset : contextualRailTopInset
    }

    static func usesShell(isPad: Bool, hasVerticalBar: Bool, sizeClass: UserInterfaceSizeClass?) -> Bool {
        isPad || (hasVerticalBar && sizeClass == .regular)
    }

    var usesCompactNavigation: Bool { width < Self.compactWindowWidth }
    var inset: CGFloat { Self.outerInset }
    var gutter: CGFloat { inset }
    var railGutter: CGFloat { usesCompactNavigation ? 0 : gutter }
    var preferredSidebarWidth: CGFloat {
        if usesFoldableLayout {
            let reclaimedRail = Self.railWidth + gutter
            return min(Self.smallSidebarWidth, max(0, contentWidth - reclaimedRail) / Self.foldableSidebarDivisor + reclaimedRail)
        }
        return width >= Self.largeWindowWidth ? Self.largeSidebarWidth : Self.smallSidebarWidth
    }
    var availableWidth: CGFloat { max(0, width - leadingInset - trailingInset) }
    var leadingInset: CGFloat { usesFoldableLayout && usesLeadingVerticalBar ? 0 : inset }
    var trailingInset: CGFloat { usesFoldableLayout && !usesLeadingVerticalBar ? 0 : inset }
    var railLeadingInset: CGFloat { usesCompactNavigation || usesFoldableLayout ? 0 : Self.railWidth + railGutter }
    var focusedPanelWidth: CGFloat { min(Self.focusPanelWidth, availableWidth) }
    var focusedPanelLeadingInset: CGFloat { (availableWidth - focusedPanelWidth) / 2 }
    var contentWidth: CGFloat { max(0, availableWidth - railLeadingInset) }
    var sidebarWidth: CGFloat { usesCompactNavigation ? contentWidth : min(preferredSidebarWidth, contentWidth) }
    var usesSidebarOverlay: Bool {
        let minimumDetail = isAccessibilitySize ? Self.accessibleDetailWidth : Self.minimumDetailWidth
        return contentWidth < preferredSidebarWidth + gutter + minimumDetail
    }

    func detailLeadingInset(sidebarVisible: Bool) -> CGFloat {
        sidebarVisible && !usesSidebarOverlay ? sidebarWidth + gutter : 0
    }
}

/// iPad shell roles keep the surrounding chrome distinct from the main panel.
/// Reuse the approved colors without changing connection or onboarding palettes.
enum IPadShellStyle {
    static func background(for scheme: ColorScheme) -> Color {
        Constants.Conversation.Design.Palette.surface(for: scheme)
    }

    static func panel(for scheme: ColorScheme) -> Color {
        Constants.Conversation.Design.Palette.background(for: scheme)
    }

    static func selection(for scheme: ColorScheme) -> Color {
        Constants.Conversation.Design.Palette.raisedSurface(for: scheme)
    }
}
