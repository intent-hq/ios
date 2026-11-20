import CoreGraphics

enum ComposerHost: Equatable {
    case floatingOrnament
    case inline

    static func forPlatform(isVisionOS: Bool) -> Self {
        isVisionOS ? .floatingOrnament : .inline
    }
}

enum FloatingComposerPresentation: Equatable {
    case covered
    case shown
    case withdrawn

    var revealsComposer: Bool { self == .shown }
}

enum FloatingComposerPolicy {
    static let horizontalMargin: CGFloat = 24
    static let minimumWidth: CGFloat = 320
    static let maximumWidth: CGFloat = 760
    static let contentInset: CGFloat = 10
    static let cornerRadius: CGFloat = 48

    static func presentation(
        isActiveChat: Bool,
        isForemost: Bool,
        showsLoadingState: Bool,
        composerVisible: Bool
    ) -> FloatingComposerPresentation {
        guard isActiveChat, !showsLoadingState, composerVisible else { return .withdrawn }
        return isForemost ? .shown : .covered
    }

    static func cancelsPhotoImport(
        from old: FloatingComposerPresentation,
        to new: FloatingComposerPresentation
    ) -> Bool {
        new == .withdrawn && old != .withdrawn
    }

    static func width(forColumnWidth columnWidth: CGFloat) -> CGFloat? {
        guard columnWidth > 0 else { return nil }
        let available = columnWidth - horizontalMargin * 2
        let floor = min(minimumWidth, columnWidth)
        return min(max(available, floor), maximumWidth)
    }

    static func questionRegionLauncherTop(
        host: ComposerHost,
        questionInputTop: CGFloat?,
        hasQuestionContent: Bool,
        composerVisible: Bool,
        usesPhoneQuestionPresentation: Bool,
        accessoryRowsTop: CGFloat? = nil
    ) -> CGFloat? {
        switch host {
        case .floatingOrnament:
            accessoryRowsTop ?? (hasQuestionContent ? questionInputTop : nil)
        case .inline:
            composerVisible || usesPhoneQuestionPresentation ? nil : questionInputTop
        }
    }
}

struct FloatingComposerLifecycle: Equatable {
    private(set) var isActiveChat = false
    private(set) var presentation: FloatingComposerPresentation = .withdrawn

    mutating func appear(
        isForemost: Bool,
        showsLoadingState: Bool,
        composerVisible: Bool
    ) {
        isActiveChat = true
        presentation = FloatingComposerPolicy.presentation(
            isActiveChat: true,
            isForemost: isForemost,
            showsLoadingState: showsLoadingState,
            composerVisible: composerVisible
        )
    }

    @discardableResult
    mutating func sync(
        isForemost: Bool,
        showsLoadingState: Bool,
        composerVisible: Bool
    ) -> Bool {
        let next = FloatingComposerPolicy.presentation(
            isActiveChat: isActiveChat,
            isForemost: isForemost,
            showsLoadingState: showsLoadingState,
            composerVisible: composerVisible
        )
        return applyPresentation(next)
    }

    @discardableResult
    mutating func updateActiveChat(
        _ active: Bool,
        isForemost: Bool,
        showsLoadingState: Bool,
        composerVisible: Bool
    ) -> Bool {
        isActiveChat = active
        return sync(
            isForemost: isForemost,
            showsLoadingState: showsLoadingState,
            composerVisible: composerVisible
        )
    }

    @discardableResult
    mutating func applyPresentation(_ next: FloatingComposerPresentation) -> Bool {
        let old = presentation
        presentation = next
        return FloatingComposerPolicy.cancelsPhotoImport(from: old, to: next)
    }

    @discardableResult
    mutating func disappear() -> Bool {
        isActiveChat = false
        return applyPresentation(.withdrawn)
    }
}
