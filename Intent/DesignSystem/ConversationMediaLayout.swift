import SwiftUI

extension Constants.Conversation {
    enum ContentBlock {
        static let thinkingTopPadding: CGFloat = 4
        static let thinkingLabelSpacing: CGFloat = 4
        static let hydratingImageOpacity: Double = 0.6
        static let loadedImageOpacity: Double = 1
        static let loadingLabelSpacing: CGFloat = 4
        static let fileLabelSpacing: CGFloat = 6
        static let fileHorizontalPadding: CGFloat = 10
        static let fileVerticalPadding: CGFloat = 6
        static let fileBackgroundOpacity: Double = 0.5
        static let fileCornerRadius: CGFloat = 6
    }

    enum ImagePlaceholder {
        /// Shared by the failure view and Textual's intrinsic-size calculation.
        nonisolated static let failureLabelSpacing: CGFloat = 4
        static let loadingLabelSpacing: CGFloat = 2
        static let backgroundOpacity: Double = 0.5
    }
}

extension Constants.Conversation.ImageThumbnail {
    /// Assistant image blocks and markdown images share the 160pt square.
    nonisolated static let transcriptSide: CGFloat = 160
    static let attachmentSide: CGFloat = 60
}

extension Constants.Conversation.ContextMention {
    static let labelSpacing: CGFloat = 4
    static let iconOpacity: Double = 0.6
    static let horizontalPadding: CGFloat = 8
    static let verticalPadding: CGFloat = 3
    static let backgroundOpacity: Double = 0.7
    static let cornerRadius: CGFloat = 5
    nonisolated static let flowSpacing: CGFloat = 6
}

extension Constants.Conversation.ImageLightbox {
    static let actionSpacing: CGFloat = 8
    static let actionContainerPadding: CGFloat = 12
    static let actionButtonPadding: CGFloat = 10
    static let actionButtonBackgroundOpacity: Double = 0.15
}
