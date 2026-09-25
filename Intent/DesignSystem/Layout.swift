import Foundation
import SwiftUI

extension Constants.Conversation {
    enum StatusStrip {
        static let contentSpacing: CGFloat = 6
        static let horizontalPadding: CGFloat = 16
        static let verticalPadding: CGFloat = 6
        static let backgroundOpacity: Double = 0.8
        static let contentOpacity: Double = 0.85
        static let chipSpacing: CGFloat = 4
        static let chipHorizontalPadding: CGFloat = 8
        static let chipCornerRadius: CGFloat = 6
        static let chipBorderOpacity: Double = 0.4
        static let chipBorderWidth: CGFloat = 1
    }

    enum NoticeCard {
        static let contentSpacing: CGFloat = 10
        static let iconTopPadding: CGFloat = 1
        static let horizontalPadding: CGFloat = 12
        static let verticalPadding: CGFloat = 10
        static let backgroundOpacity: Double = 0.1
        static let cornerRadius: CGFloat = 8
        static let borderOpacity: Double = 0.3
        static let borderWidth: CGFloat = 1
    }

    enum DividerNotice {
        static let outerSpacing: CGFloat = 12
        static let labelSpacing: CGFloat = 6
        static let verticalPadding: CGFloat = 8
        static let lineHeight: CGFloat = 1
    }

    enum QueuedMessage {
        static let actionButtonSide: CGFloat = 36
    }

    enum ImageThumbnail {
        static let cornerRadius: CGFloat = 8
        static let borderWidth: CGFloat = 0.5
    }
}

extension Constants.Conversation.Attribution {
    static let spacing: CGFloat = 6
    static let expansionAnimationDuration: Double = 0.2
}

extension Constants.Conversation.AgentWaiting {
    static let progressScale: CGFloat = 0.7
    static let fallbackProgressScale: CGFloat = 0.6
    static let rowHeight: CGFloat = 44
    static let maximumListHeight: CGFloat = 132
    static let fallbackRowHeight: CGFloat = 40
    static let fallbackMaximumListHeight: CGFloat = 120
    static let avatarSize: CGFloat = 22
    static let badgeFontSize: CGFloat = 8
    static let badgeSize: CGFloat = 10
    static let badgeOffset: CGFloat = 2
    static let activeDotSize: CGFloat = 5
    static let activeDotOffset: CGFloat = 1
}

extension Constants.Conversation.Message {
    static let contextPreviewMaximumWidth: CGFloat = 320
}

extension Constants.Conversation.Composer {
    static let maximumTextViewHeight: CGFloat = 120
    static let pendingImageSide: CGFloat = 56
    static let pendingFileMaximumWidth: CGFloat = 200
    static let textContainerInset: CGFloat = 4
    // Composer control hit target: visionOS gaze targeting needs ≥60 pt
    // (HIG); other platforms keep the 44 pt tap minimum.
    #if os(visionOS)
    static let controlTarget: CGFloat = 60
    // The empty field matches the 60 pt side controls exactly: minimum text
    // view height equals the control target with no outer vertical padding,
    // capsule corners, and short content vertically centered by
    // KeyCommandTextView.
    static let minimumTextViewHeight: CGFloat = controlTarget
    static let fieldVerticalPadding: CGFloat = 0
    static let fieldCornerRadius: CGFloat = 30
    static let suggestedPromptChipMinimumHeight: CGFloat = 60
    static let suggestedPromptChipSpacing: CGFloat = 12
    #else
    static let controlTarget: CGFloat = Constants.Accessibility.minimumTapTarget
    static let minimumTextViewHeight = Constants.Accessibility.minimumTapTarget
    static let fieldVerticalPadding: CGFloat = 4
    static let fieldCornerRadius: CGFloat = 18
    #endif
}

extension Constants.Conversation.Column {
    static let chromeAnimationDuration: Double = 0.25
}

extension Constants.Conversation.Sending {
    static let messageAppendSpringResponse: Double = 0.35
    static let messageAppendSpringDamping: Double = 0.7
    static let stateTransitionAnimationDuration: Double = 0.2
}

extension Constants.Conversation.Transcript {
    static let scrollAnimationDuration: Double = 0.2
    static let goToEndVisibilityAnimationDuration: Double = 0.2
}

extension Constants.Conversation.QuestionWizard {
    static let animationDuration: Double = 0.15
    static let contentHorizontalPadding: CGFloat = 14
    static let controlSpacing: CGFloat = 10
    static let optionSpacing: CGFloat = 6
    static let optionHorizontalPadding: CGFloat = 10
    static let optionVerticalPadding: CGFloat = 8
    static let optionCornerRadius: CGFloat = 8
    static let bodyHeightFraction: CGFloat = 0.5
    static let fallbackBodyMaximumHeight: CGFloat = 320
    static let progressSegmentWidth: CGFloat = 14
    static let progressSegmentHeight: CGFloat = 4
    static let progressSegmentCornerRadius: CGFloat = 2
    static let checkboxSide: CGFloat = 15
    static let checkboxCornerRadius: CGFloat = 4
    // Free-text answer grows from one line up to this many, then scrolls.
    static let freeTextMaximumLineCount = 6
}

extension Constants.Conversation.ResponseGroup {
    static let expansionAnimationDuration: Double = 0.25
    static let contentIndent: CGFloat = 18
    static let railInset: CGFloat = 8
    static let railWidth: CGFloat = 1
    static let collapsedMaximumHeight: CGFloat = 100
    static let collapsedFadeHeight: CGFloat = 24
}

extension Constants.Conversation.ToolCall {
    static let expansionAnimationDuration: Double = 0.2
    static let outputMaximumHeight: CGFloat = 200
}

extension Constants.Conversation.ImageLightbox {
    static let springAnimationDuration: Double = 0.3
}

extension Constants.Notification {
    static let presentationSpringResponse: Double = 0.4
    static let presentationSpringDamping: Double = 0.85
    static let dismissalAnimationDuration: Double = 0.25
}

extension Constants.Root {
    static let visionDefaultWindowWidth: CGFloat = 1280
    static let visionDefaultWindowHeight: CGFloat = 900
    static let visionMinimumWindowWidth: CGFloat = 800
    static let visionMinimumWindowHeight: CGFloat = 600
    static let sidebarMinimumWidth: CGFloat = 300
    static let sidebarIdealWidth: CGFloat = 350
    static let sidebarMaximumWidth: CGFloat = 400
    static let screenAnimationDuration: Double = 0.3
    static let toastTopPadding: CGFloat = 8
    static let reconnectBackdropOpacity: Double = 0.15
    static let reconnectPanelSpacing: CGFloat = 16
    static let reconnectProgressScale: CGFloat = 1.2
    static let reconnectButtonTopPadding: CGFloat = 8
    static let reconnectPanelPadding: CGFloat = 32
    static let reconnectPanelCornerRadius: CGFloat = 20
    static let backButtonSpacing: CGFloat = 4
    static let emptyStateSpacing: CGFloat = 12
    static let emptyStateHorizontalPadding: CGFloat = 24
}

extension Constants.Connecting {
    static let horizontalPadding: CGFloat = 20
    static let verticalPadding: CGFloat = 12
    static let bottomPadding: CGFloat = 24
}

extension Constants.Disconnected {
    static let contentSpacing: CGFloat = 24
    static let indicatorSize: CGFloat = 12
    static let activeIndicatorScale: CGFloat = 1.5
    static let activeIndicatorOpacity: Double = 0.5
    static let indicatorAnimationDuration: Double = 1
    static let horizontalPadding: CGFloat = 32
    static let buttonVerticalPadding: CGFloat = 14
    static let buttonBackgroundOpacity: Double = 0.1
    static let buttonCornerRadius: CGFloat = 12
    static let bottomPadding: CGFloat = 32
}

extension Constants.ConnectionFailure {
    static let contentSpacing: CGFloat = 24
    static let destructiveBackgroundOpacity: Double = 0.1
    static let iconBackgroundSize: CGFloat = 80
    static let iconSize: CGFloat = 32
    static let titleSpacing: CGFloat = 8
    static let messageHorizontalPadding: CGFloat = 32
    static let controlSpacing: CGFloat = 12
    static let progressSpacing: CGFloat = 8
    static let controlVerticalPadding: CGFloat = 14
    static let controlBackgroundOpacity: Double = 0.3
    static let controlCornerRadius: CGFloat = 12
    static let savedConnectionsMaximumHeight: CGFloat = 220
    static let savedConnectionsSpacing: CGFloat = 8
    static let controlsHorizontalPadding: CGFloat = 24
    static let helpSpacing: CGFloat = 4
    static let helpHorizontalPadding: CGFloat = 32
    static let helpBottomPadding: CGFloat = 32
    static let savedConnectionRowSpacing: CGFloat = 12
    static let savedConnectionTextSpacing: CGFloat = 2
    static let savedConnectionVerticalPadding: CGFloat = 10
    static let savedConnectionHorizontalPadding: CGFloat = 12
}

extension Constants.AgentAvatar {
    static let artSizeRatio: CGFloat = 0.8
    static let cornerRadiusRatio: CGFloat = 0.3
    nonisolated static let referenceArtSize: CGFloat = 16
    static let referenceStrokeWidth: CGFloat = 1.33
    static let activeStrokeWidth: CGFloat = 1.5
    static let pulseAnimationDuration: Double = 1
}

extension Constants.AgentRow {
    static let rowSpacing: CGFloat = 10
    static let avatarSize: CGFloat = 24
    static let activeDotSize: CGFloat = 6
    static let activeDotOffset: CGFloat = 2
    static let attentionIconSize: CGFloat = 9
    static let attentionIconOffset: CGFloat = 3
    static let textSpacing: CGFloat = 2
    static let titleSpacing: CGFloat = 6
    static let badgeFontSize: CGFloat = 10
    static let badgeHorizontalPadding: CGFloat = 4
    static let badgeVerticalPadding: CGFloat = 2
    static let badgeBackgroundOpacity: Double = 0.15
    static let badgeCornerRadius: CGFloat = 4
    static let verticalPadding: CGFloat = 6
    static let nestedLeadingPadding: CGFloat = 36
    static let headerSpacing: CGFloat = 4
    static let avatarOverlap: CGFloat = -6
    static let headerAvatarSize: CGFloat = 16
    static let delegatedVerticalPadding: CGFloat = 4
    static let backgroundVerticalPadding: CGFloat = 8
}

extension Constants.WorkspaceRow {
    static let rowSpacing: CGFloat = 12
    static let statusDotSize: CGFloat = 5
    static let statusDotOffset: CGFloat = 2
    static let unreadDotStackOffset: CGFloat = 5
    static let differentiatedStatusCueSize: CGFloat = 12
    static let differentiatedStatusCueOffset: CGFloat = 4
    static let differentiatedUnreadStackOffset: CGFloat = 10
    static let titleSpacing: CGFloat = 4
    static let metadataSpacing: CGFloat = 8
    static let pillFontSize: CGFloat = 11
    static let pillHorizontalPadding: CGFloat = 6
    static let pillVerticalPadding: CGFloat = 2
    static let pillBackgroundOpacity: Double = 0.12
    static let verticalPadding: CGFloat = 6
    static let horizontalPadding: CGFloat = 4
    static let statusIconSize: CGFloat = 12
    static let statusGlyphScale: CGFloat = 0.5
    static let statusStrokeWidth: CGFloat = 1.5
    static let inactiveStatusOpacity: Double = 0.4
    // visionOS attention cue: single-step z-lift + scale on rows needing
    // input, plus a brighter status chip. No continuous animation (HIG).
    #if os(visionOS)
    static let attentionCueZOffset: CGFloat = 12
    static let attentionCueScale: CGFloat = 1.02
    static let attentionCueAnimationDuration: Double = 0.25
    static let attentionChipBrightness: Double = 0.2
    #endif
}

extension Constants.WorkspaceList {
    static let pickerHorizontalPadding: CGFloat = 16
    static let pickerVerticalPadding: CGFloat = 8
    static let emptyStateSpacing: CGFloat = 12
    static let bottomContentMargin: CGFloat = 60
    static let sidebarRowInset: CGFloat = 8
    static let sidebarSelectionCornerRadius: CGFloat = 10
    static let sidebarSectionSpacing: CGFloat = 6
    static let sidebarSectionAvatarSize: CGFloat = 16
    static let sidebarTopContentMargin: CGFloat = 4
}

extension Constants.WorkspaceSearch {
    static let buttonSize: CGFloat = 52
    static let segmentHeight: CGFloat = 44
    static let segmentInset: CGFloat = 4
    static let segmentCornerRadius: CGFloat = 16
    static let contentSpacing: CGFloat = 8
    static let horizontalPadding: CGFloat = 12
    static let verticalPadding: CGFloat = 10
    static let cornerRadius: CGFloat = 20
    static let borderOpacity: Double = 0.2
    static let borderWidth: CGFloat = 0.5
    static let bottomPadding: CGFloat = 8
    static let focusAnimationDuration: Double = 0.2
}

extension Constants.WorkspaceDetail {
    static let horizontalPadding: CGFloat = 16
    static let regularTitleTopPadding: CGFloat = 4
    static let titleBottomPadding: CGFloat = 4
    static let progressSectionSpacing: CGFloat = 4
    static let progressSpacing: CGFloat = 1
    static let progressCornerRadius: CGFloat = 2
    static let remainingProgressOpacity: Double = 0.2
    static let progressHeight: CGFloat = 4
    static let progressBottomPadding: CGFloat = 8
    static let statusImageBottomPadding: CGFloat = 8
    static let emptyStateSpacing: CGFloat = 12
    static let tabVerticalPadding: CGFloat = 8
    // visionOS deliberate confirmation sheets for destructive/irreversible
    // workspace actions (archive, delete).
    #if os(visionOS)
    static let confirmationSheetSpacing: CGFloat = 16
    static let confirmationSheetPadding: CGFloat = 32
    static let confirmationSheetWidth: CGFloat = 380
    #endif
}

extension Constants.ModalPicker {
    static let emptyStateSpacing: CGFloat = 12
    static let rowSpacing: CGFloat = 12
    static let rowTextSpacing: CGFloat = 4
    static let rowVerticalPadding: CGFloat = 4
    static let loadingOverlayOpacity: Double = 0.3
    static let loadingOverlaySpacing: CGFloat = 12
    static let loadingOverlayPadding: CGFloat = 24
    static let loadingOverlayCornerRadius: CGFloat = 12
    static let placeholderSpacing: CGFloat = 4
    static let modelLoadingSpacing: CGFloat = 8
    static let rowAvatarSize: CGFloat = 28
}

extension Constants.CreateWorkspace {
    static let errorStateSpacing: CGFloat = 12
    static let errorStatePadding: CGFloat = 24
    static let branchBadgeHorizontalPadding: CGFloat = 6
    static let branchBadgeVerticalPadding: CGFloat = 2
    static let branchBadgeOpacity: Double = 0.15
    static let branchRowVerticalPadding: CGFloat = 2
}

extension Constants.GitHubRepoPicker {
    static let rowSpacing: CGFloat = 12
    static let rowTextSpacing: CGFloat = 4
    static let rowVerticalPadding: CGFloat = 4
    static let emptyStateSpacing: CGFloat = 12
    static let emptyStateHorizontalPadding: CGFloat = 24
}

extension Constants.RepoOwnerAvatar {
    static let borderOpacity: Double = 0.2
    static let borderWidth: CGFloat = 1
    static let fallbackScale: CGFloat = 0.5
}

extension Constants.Pairing {
    // Connect frame 3051:54405. Wide windows retain a readable centered column.
    static let maximumContentWidth: CGFloat = 480
    static let contentSpacing: CGFloat = 64
    static let headerSpacing: CGFloat = 24
    static let descriptionHorizontalPadding: CGFloat = 24
    static let optionsSpacing: CGFloat = 24
    static let optionsHorizontalPadding: CGFloat = 24
    static let optionSpacing: CGFloat = 24
    static let glyphSize: CGFloat = 24
    static let iconTileSize: CGFloat = 64
    static let iconTileCornerRadius: CGFloat = 16
    static let optionTextSpacing: CGFloat = 12
    static let optionPadding: CGFloat = 24
    static let optionCornerRadius: CGFloat = 40
    static let headingTracking: CGFloat = -0.56
    static let optionTitleTracking: CGFloat = -0.32
    static let bodyTracking: CGFloat = -0.16
}

extension Constants.Settings {
    static let contentSpacing: CGFloat = 20
    static let sectionSpacing: CGFloat = 12
    static let cardPadding: CGFloat = 16
    static let cardCornerRadius: CGFloat = 12
    static let cardBorderWidth: CGFloat = 1
    static let connectionRowSpacing: CGFloat = 12
    static let connectionTextSpacing: CGFloat = 2
    static let statusSpacing: CGFloat = 4
    static let statusDotSize: CGFloat = 8
    static let contentPadding: CGFloat = 20
    static let backButtonSpacing: CGFloat = 4
}

extension Constants.Connections {
    static let rowSpacing: CGFloat = 12
    static let rowTextSpacing: CGFloat = 2
    static let statusSpacing: CGFloat = 4
    static let statusDotSize: CGFloat = 8
}

extension Constants.Notes.Content {
    static let segmentSpacing: CGFloat = 8
    static let indentWidthPerColumn: CGFloat = 6
    static let taskRowSpacing: CGFloat = 8
    static let taskIconSize: CGFloat = 18
    static let taskIconTopPadding: CGFloat = 2
    static let linkedTaskSpacing: CGFloat = 10
    static let linkedTaskHorizontalPadding: CGFloat = 10
    static let linkedTaskVerticalPadding: CGFloat = 8
    static let linkedTaskCornerRadius: CGFloat = 6
    static let linkedTaskBorderWidth: CGFloat = 1
}

extension Constants.Notes.Detail {
    static let contentSpacing: CGFloat = 12
    static let tagSpacing: CGFloat = 4
    static let tagHorizontalPadding: CGFloat = 8
    static let tagVerticalPadding: CGFloat = 3
    static let tagCornerRadius: CGFloat = 6
    static let contentPadding: CGFloat = 16
}

extension Constants.Notes.List {
    static let emptyStateSpacing: CGFloat = 12
    static let horizontalPadding: CGFloat = 16
    static let expansionAnimationDuration: Double = 0.2
    static let indentationWidth: CGFloat = 24
    static let rowSpacing: CGFloat = 6
    static let disclosureSize: CGFloat = 28
    static let contentSpacing: CGFloat = 4
    static let titleSpacing: CGFloat = 2
    static let tagHorizontalPadding: CGFloat = 6
    static let tagVerticalPadding: CGFloat = 2
    static let tagCornerRadius: CGFloat = 4
    static let rootVerticalPadding: CGFloat = 10
    static let nestedVerticalPadding: CGFloat = 9
    static let horizontalRowPadding: CGFloat = 4
}

extension Constants.Notes.Metadata {
    static let sectionSpacing: CGFloat = 6
    static let rowSpacing: CGFloat = 8
    static let labelWidth: CGFloat = 110
    static let verticalPadding: CGFloat = 3
    static let chipStackSpacing: CGFloat = 4
    static let chipHorizontalPadding: CGFloat = 8
    static let chipCornerRadius: CGFloat = 6
    static let statusIconSize: CGFloat = 16
    static let relationIconSize: CGFloat = 14
    static let relationSpacing: CGFloat = 6
    static let warningBackgroundOpacity: Double = 0.12
    static let mutedBackgroundOpacity: Double = 0.4
}

extension Constants.Toast {
    static let contentSpacing: CGFloat = 12
    static let textSpacing: CGFloat = 2
    static let horizontalPadding: CGFloat = 16
    static let verticalPadding: CGFloat = 12
    static let cornerRadius: CGFloat = 14
    static let shadowOpacity: Double = 0.15
    static let shadowRadius: CGFloat = 12
    static let shadowYOffset: CGFloat = 4
    static let outerHorizontalPadding: CGFloat = 12
    static let resetSpringResponse: Double = 0.3
    static let resetSpringDamping: Double = 0.7
}

extension Constants.QRScanner {
    static let unavailableMessagePadding: CGFloat = 24
    static let statusSpacing: CGFloat = 8
    static let statusPadding: CGFloat = 20
    static let statusBackgroundOpacity: Double = 0.7
    static let statusCornerRadius: CGFloat = 12
    static let statusBottomPadding: CGFloat = 60
}

extension Constants.Loading {
    private static let phaseDurationMilliseconds = 1200
    static let phaseDuration: Duration = .milliseconds(Self.phaseDurationMilliseconds)
}

extension Constants.Splash {
    static let maximumLogoDimension: CGFloat = 100
}
