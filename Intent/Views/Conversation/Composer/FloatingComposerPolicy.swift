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

/// How a chat's floating composer is presented.
enum FloatingComposerPresentation: Equatable {
    /// Hidden while a modal layer covers the chat. Temporary: an in-flight
    /// photo import keeps running so its attachment is waiting on dismissal.
    case covered
    /// Visible, interactive and exposed to accessibility: the chat in front.
    case shown
    /// The chat went away (navigation, loading, question slot): an in-flight
    /// photo import is cancelled, as when the inline composer unmounts.
    case withdrawn

    var revealsComposer: Bool { self == .shown }
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
    /// slot leaves the composer available), and only for the chat in front:
    /// a pushed child agent (`isActiveChat`) withdraws it, and a covering
    /// modal layer such as the Assistant sheet (`isForemost`, from
    /// `ComposerCoverage`) hides it, so each window shows exactly one composer.
    static func presentation(
        isActiveChat: Bool,
        isForemost: Bool,
        showsLoadingState: Bool,
        composerVisible: Bool
    ) -> FloatingComposerPresentation {
        guard isActiveChat, !showsLoadingState, composerVisible else { return .withdrawn }
        return isForemost ? .shown : .covered
    }

    /// Whether a presentation change ends the chat's in-flight photo import.
    /// Only a genuine withdrawal does; being covered by a modal does not.
    static func cancelsPhotoImport(
        from old: FloatingComposerPresentation,
        to new: FloatingComposerPresentation
    ) -> Bool {
        new == .withdrawn && old != .withdrawn
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
