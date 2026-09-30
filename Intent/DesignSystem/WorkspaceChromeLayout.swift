import SwiftUI

extension Constants.Root {
    static let reconnectPanelMaximumWidth: CGFloat = 320
}

extension Constants.Connecting {
    static let mismatchHorizontalPadding: CGFloat = 32
    static let contentBottomPadding: CGFloat = 24
}

extension Constants.Settings {
    enum Acknowledgements {
        static let entrySpacing: CGFloat = 12
        static let licenseSpacing: CGFloat = 8
    }
}

extension Constants.WorkspaceRow {
    nonisolated static let titleLineLimit = 2
    static let pillBorderWidth: CGFloat = 1
    static let increasedContrastPillBorderWidth: CGFloat = 2
    static let outlinedPillHorizontalPadding: CGFloat = 8
    static let outlinedPillMinimumHeight: CGFloat = 24
    static let pillIconSize: CGFloat = 12
    static let pillIconSpacing: CGFloat = 7
    static let pillSpacing: CGFloat = 4
    static let pillOutlineOpacity = 0.1
}

extension Constants.WorkspaceDetail {
    static let increasedRemainingOpacity: Double = 0.55
    static let increasedContrastProgressBorderWidth: CGFloat = 1.5
}

extension WorkspaceStatusImageLayout {
    /// Row thumbnail side (matches the list's status-icon scale).
    nonisolated static let cardThumbnailSide: CGFloat = 44
    /// Detail banner cap — the desktop card's `max-h-48`.
    nonisolated static let detailMaxHeight: CGFloat = 192
    nonisolated static let cornerRadius: CGFloat = 8
    nonisolated static let borderWidth: CGFloat = 0.5
    nonisolated static let detailPlaceholderHeight: CGFloat = 44
    nonisolated static let placeholderSpacing: CGFloat = 6
    nonisolated static let placeholderOpacity: Double = 0.5
}

extension Constants.Notes.List {
    static let leadingIconSize: CGFloat = 14
    static let previewLineLimit = 2
    static let titleLineLimit = 2
    static let accessibilityIndentSpacingMultiplier: CGFloat = 2
}

extension Constants.CreateWorkspace {
    static let branchNameLineLimit = 2
    static let contextValueLineLimit = 2
}

extension Constants.GitHubRepoPicker {
    static let repositoryNameLineLimit = 2
}
