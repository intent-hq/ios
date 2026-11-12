import SwiftUI

extension Constants.Conversation.Transcript {
    static let transcriptRowSpacing: CGFloat = 16
    static let transcriptHorizontalPadding: CGFloat = 16
    static let transcriptTopPadding: CGFloat = 24
    static let bottomAnchorHeight: CGFloat = 8
    static let bottomAnchorPadding: CGFloat = 12
    static let goToEndSpacing: CGFloat = 4
    static let goToEndHorizontalPadding: CGFloat = 14
    static let goToEndVerticalPadding: CGFloat = 8
    static let goToEndShadowOpacity: Double = 0.15
    static let goToEndShadowRadius: CGFloat = 4
    static let goToEndShadowYOffset: CGFloat = 2
    static let goToEndBottomPadding: CGFloat = 8
    static let thinkingIndicatorSpacing: CGFloat = 6
    static let thinkingIndicatorScale: Double = 0.7
    static let thinkingIndicatorSide: CGFloat = 16
    static let thinkingIndicatorHorizontalPadding: CGFloat = 12
    static let thinkingIndicatorVerticalPadding: CGFloat = 4
    static let suggestedPromptSpacing: CGFloat = 8
    static let suggestedPromptHorizontalPadding: CGFloat = 14
    static let suggestedPromptVerticalPadding: CGFloat = 10
    static let suggestedPromptBackgroundOpacity: Double = 0.4
    static let suggestedPromptCornerRadius: CGFloat = 10
    static let suggestedPromptBorderOpacity: Double = 0.3
    static let suggestedPromptBorderWidth: CGFloat = 1
    static let truncationBannerSpacing: CGFloat = 8
    static let truncationBannerHorizontalPadding: CGFloat = 16
    static let truncationBannerVerticalPadding: CGFloat = 12
    static let truncationBannerBackgroundOpacity: Double = 0.5
    static let truncationBannerCornerRadius: CGFloat = 10
}

extension Constants.Conversation.Design {
    enum SuggestedPrompt {
        static let contentSpacing = Constants.Conversation.Design.Status.iconSpacing
        static let horizontalPadding = Constants.Conversation.Design.Question.buttonHorizontalPadding
        static let verticalPadding: CGFloat = 12
        static let minimumHeight = Constants.Conversation.Design.Composer.minimumHeight
        static let borderWidth: CGFloat = 1
        static let pressedOverlayOpacity: Double = 0.08
        static let disabledOpacity: Double = 0.4
    }

    enum HistoryNotice {
        static let contentSpacing = Constants.Conversation.Design.Status.iconSpacing
        static let horizontalPadding = Constants.Conversation.Design.Status.leadingPadding
        static let verticalPadding: CGFloat = 12
    }
}

extension Constants.Conversation.Column {
    static let questionBannerBackgroundOpacity: Double = 0.4
    static let questionBannerCornerRadius: CGFloat = 12
    static let questionBannerHorizontalPadding: CGFloat = 8
    static let questionBannerVerticalPadding: CGFloat = 8
    static let questionWizardHorizontalPadding: CGFloat = 8
    static let questionWizardTopPadding: CGFloat = 8
    static let collapsedQuestionWizardBottomPadding: CGFloat = 4
    static let expandedQuestionWizardBottomPadding: CGFloat = 8
    static let questionSheetPadding: CGFloat = 24

    enum PendingQuestionRecovery {
        static let contentSpacing: CGFloat = 8
        static let verticalPadding: CGFloat = 12
    }

    enum Loading {
        static let iconDimension: CGFloat = 20
        static let contentSpacing: CGFloat = 12
        static let rowSpacing: CGFloat = 16
        static let retryTopPadding: CGFloat = 12
        static let statusThreshold: TimeInterval = 5
        static let slowThreshold: TimeInterval = 8
        static let timelineInterval: TimeInterval = 1
        static let fadeDuration: Double = 0.2
    }

    enum Empty {
        static let contentSpacing: CGFloat = 12
        static let descriptionHorizontalPadding: CGFloat = 32
        static let modelCaptionOpacity: Double = 0.7
        static let modelCaptionTopPadding: CGFloat = 4
    }
}

extension Constants.Conversation {
    enum UserMessage {
        static let contentSpacing: CGFloat = 4
        static let attachmentGridSpacing: CGFloat = 6
        static let attachmentSectionTopPadding: CGFloat = 4
        static let fileAttachmentListSpacing: CGFloat = 4
        static let containerPadding: CGFloat = 12
        static let backgroundOpacity: Double = 0.4
        static let cornerRadius: CGFloat = 8
        static let textRowSpacing: CGFloat = 6
        static let mentionChipSpacing: CGFloat = 6
        static let textOpacity: Double = 0.85
        static let fileChipSpacing: CGFloat = 6
        static let fileChipHorizontalPadding: CGFloat = 8
        static let fileChipVerticalPadding: CGFloat = 5
        static let fileChipBackgroundOpacity: Double = 0.6
        static let fileChipCornerRadius: CGFloat = 8
    }

    enum AssistantMessage {
        static let contentSpacing: CGFloat = 8
        static let verticalPadding: CGFloat = 4
    }

    enum ErrorMessage {
        static let spacing: CGFloat = 6
        static let padding: CGFloat = 10
        static let backgroundOpacity: Double = 0.1
        static let cornerRadius: CGFloat = 8
    }

    enum NewMessagesDivider {
        static let contentSpacing: CGFloat = 8
        static let labelSpacing: CGFloat = 6
        static let iconOpacity: Double = 0.7
        static let labelHorizontalPadding: CGFloat = 4
        static let horizontalPadding: CGFloat = 8
        static let verticalPadding: CGFloat = 4
        static let hairlinePixelHeight: CGFloat = 1
        static let minimumDisplayScale: CGFloat = 1
        static let minimumLineWidth: CGFloat = 16
    }
}

extension Constants.Conversation.CopyContextMenu {
    static let previewPadding: CGFloat = 12
}

extension Constants.Conversation.ResponseGroup {
    static let groupSpacing: CGFloat = 4
    static let headerSpacing: CGFloat = 6
    static let iconOpacity: Double = 0.6
    static let countHorizontalPadding: CGFloat = 5
    static let countVerticalPadding: CGFloat = 1
    static let disclosureOpacity: Double = 0.4
    static let headerVerticalPadding: CGFloat = 4
    static let railOpacity: Double = 0.15
    static let bottomPadding: CGFloat = 8
    static let childSpacing: CGFloat = 8
}

extension Constants.Conversation.ToolCall {
    static let iconSize: CGFloat = 16
    static let headerSpacing: CGFloat = 4
    static let pathOpacity: Double = 0.6
    static let disclosureFontSize: CGFloat = 8
    static let disclosureOpacity: Double = 0.4
    static let headerLeadingPadding: CGFloat = 8
    static let headerVerticalPadding: CGFloat = 3
    static let expandedContentSpacing: CGFloat = 8
    static let hydrationStatusSpacing: CGFloat = 4
    static let expandedHorizontalPadding: CGFloat = 10
    static let expandedBottomPadding: CGFloat = 10
    static let successBorderOpacity: Double = 0.5
    static let statusBorderWidth: CGFloat = 2
}

extension Constants.Conversation.NoticeCard {
    static let increasedContrastBackgroundMultiplier: Double = 1.75
    static let increasedContrastBorderWidthMultiplier: CGFloat = 2
    static let attentionTextSpacing: CGFloat = 2
    /// Gap between the turn-failure summary, link, and Details sections.
    static let turnFailureSectionSpacing: CGFloat = 6
    static let turnFailureActionSpacing: CGFloat = 4
    static let turnFailureDetailsPadding: CGFloat = 8
    static let turnFailureDetailsCornerRadius: CGFloat = 6
    static let turnFailureDetailsBackgroundOpacity: Double = 0.06
    static let turnFailureDetailsIncreasedOpacity: Double = 0.12
}

extension Constants.Conversation.DividerNotice {
    static let minimumLineWidth: CGFloat = 16
}

extension Constants.Conversation.AgentWaiting {
    static let headerSpacing: CGFloat = 8
    static let horizontalPadding: CGFloat = 16
    static let headerVerticalPadding: CGFloat = 8
    static let fallbackRowSpacing: CGFloat = 10
    static let rowVerticalPadding: CGFloat = 6
    static let agentRowSpacing: CGFloat = 8
    static let descriptionSpacing: CGFloat = 2
}

extension Constants.Conversation.StatusStrip {
    enum BackgroundHooks {
        /// Max characters of a hook name shown on a chip (mirrors the FE's
        /// visual max-width truncation).
        static let nameMaxLength = 24
        static let repeatIconFontSize: CGFloat = 8
        static let chipTopPadding: CGFloat = 4
        static let chipBottomPadding: CGFloat = 6
        static let chipBackgroundOpacity: Double = 0.3
        static let timeBarInset: CGFloat = 3
        static let timeBarOpacity: Double = 0.5
        static let timeBarHeight: CGFloat = 1
    }

    enum MonitoredPrs {
        static let pendingIndicatorOpacity: Double = 0.8
        static let pendingIndicatorSide: CGFloat = 6
        static let chipVerticalPadding: CGFloat = 5
        static let chipBackgroundOpacity: Double = 0.3
    }
}
