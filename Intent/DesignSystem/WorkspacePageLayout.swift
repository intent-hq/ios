import SwiftUI

extension Constants.WorkspaceList {
    static let pageInset: CGFloat = 24
    static let titleTopSpacing: CGFloat = 64
    static let titleBottomSpacing: CGFloat = 64
    static let searchTitleSpacing: CGFloat = 16
    static let groupTopSpacing: CGFloat = 32
    static let groupBottomSpacing: CGFloat = 12
    static let emptyStateHeight: CGFloat = 240

    static func canvas(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Constants.Pairing.background(for: scheme) : Theme.background(for: scheme)
    }

    static func controlSurface(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Constants.Pairing.surface(for: scheme) : Constants.Pairing.background(for: scheme)
    }
}

extension Constants.WorkspaceSearch {
    static let compactHeight: CGFloat = 48
    static let expandedHeight: CGFloat = 56
    static let iconSize: CGFloat = 24
    static let inputLeadingInset: CGFloat = 20
    static let compactSegmentInset: CGFloat = 2
}

extension Constants.WorkspaceRow {
    static let spaciousPadding: CGFloat = 24
    static let spaciousTitleSpacing: CGFloat = 10
    static let spaciousRowSpacing: CGFloat = 20
}
