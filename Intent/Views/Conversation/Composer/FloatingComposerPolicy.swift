import CoreGraphics

/// Where a chat column hosts its composer. visionOS floats the composer in a
/// bottom ornament just outside the window; every iOS presentation keeps it
/// inline at the bottom of the column, unchanged.
enum ComposerHost: Equatable {
    case floatingOrnament
    case inline

    static func forPlatform(isVisionOS: Bool) -> Self {
        isVisionOS ? .floatingOrnament : .inline
    }
}

/// Presentation rules for the floating (ornament) composer. Platform-neutral
/// so the iOS unit-test host can pin them; only the ornament itself is
/// visionOS-specific (ConversationColumnView).
enum FloatingComposerPolicy {
    /// Gap kept between the ornament and each side of the chat column.
    static let horizontalMargin: CGFloat = 24
    /// Narrowest composer before it stops shrinking with the column.
    static let minimumWidth: CGFloat = 320
    /// Widest composer, matching a comfortable reading measure on wide windows.
    static let maximumWidth: CGFloat = 760
    /// Inset between the glass edge and the composer, keeping pending
    /// attachment previews clear of the rounded corners.
    static let contentInset: CGFloat = 10
    /// Corner radius of the glass container: the 60 pt field capsule's 30 pt
    /// radius plus the input row's 8 pt vertical padding and `contentInset`,
    /// so the field and container curves stay concentric.
    static let cornerRadius: CGFloat = 48

    /// The floating composer appears under the same conditions as the inline
    /// one (not while the transcript is loading, and only when the question
    /// slot leaves the composer available). It is also withdrawn while its
    /// chat is covered — a pushed child agent owns the window's ornament — so
    /// each window shows at most one composer, for the chat in front.
    static func isPresented(
        isActiveChat: Bool,
        showsLoadingState: Bool,
        composerVisible: Bool
    ) -> Bool {
        isActiveChat && !showsLoadingState && composerVisible
    }

    /// Composer width that tracks the chat column, so resizing the window
    /// resizes the ornament. Nil until the column has been measured.
    static func width(forColumnWidth columnWidth: CGFloat) -> CGFloat? {
        guard columnWidth > 0 else { return nil }
        let available = columnWidth - horizontalMargin * 2
        // Never wider than the column itself when the window is very narrow.
        let floor = min(minimumWidth, columnWidth)
        return min(max(available, floor), maximumWidth)
    }

    /// The top edge the workspace action launcher must stay above, reported
    /// from the question region. Inline hosts report it only when the
    /// question slot replaces the composer (the composer reports its own top
    /// otherwise). A floating composer lives outside the window, so the
    /// question region is the lowest in-window input whenever it shows
    /// content; an empty region reports nothing rather than a stale top.
    static func questionRegionLauncherTop(
        host: ComposerHost,
        questionInputTop: CGFloat?,
        hasQuestionContent: Bool,
        composerVisible: Bool,
        usesPhoneQuestionPresentation: Bool
    ) -> CGFloat? {
        switch host {
        case .floatingOrnament:
            hasQuestionContent ? questionInputTop : nil
        case .inline:
            composerVisible || usesPhoneQuestionPresentation ? nil : questionInputTop
        }
    }
}
