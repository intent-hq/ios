import SwiftUI

extension Constants.Conversation.QuestionWizard {
    enum Step {
        static let titleSpacing: CGFloat = 3
        static let headerKerning: CGFloat = 0.5
        static let contentTopPadding: CGFloat = 10
        static let contentBottomPadding: CGFloat = 8
        static let optionLabelSpacing: CGFloat = 1
        static let secondaryLabelOpacity: Double = 0.6
        static let selectedHighContrastOpacity: Double = 0.2
        static let selectedOpacity: Double = 0.1
        static let optionBackgroundOpacity: Double = 0.6
        static let standardBorderOpacity: Double = 0.4
        static let optionEmphasizedBorderWidth: CGFloat = 2
        static let optionBorderWidth: CGFloat = 1
        static let checkboxBorderOpacity: Double = 0.5
        static let checkboxIncreasedBorderWidth: CGFloat = 2
        static let checkboxBorderWidth: CGFloat = 1
        static let otherFieldSpacing: CGFloat = 8
        static let otherFieldBackgroundOpacity: Double = 0.7
        static let returnHintOpacity: Double = 0.5
        // Matches UITextView's default line-fragment padding for placeholder alignment.
        static let lineFragmentPadding: CGFloat = 5
    }

    enum Surface {
        static let backgroundIncreasedOpacity: Double = 0.7
        static let backgroundOpacity: Double = 0.4
        static let cornerRadius: CGFloat = 12
        static let standardBorderOpacity: Double = 0.3
        static let increasedBorderWidth: CGFloat = 2
        static let borderWidth: CGFloat = 1
    }

    enum Header {
        static let progressSegmentSpacing: CGFloat = 4
        static let multiSelectHorizontalPadding: CGFloat = 7
        static let multiSelectVerticalPadding: CGFloat = 1
        static let multiSelectFillOpacity: Double = 0.8
        static let minimumContentSpacing: CGFloat = 8
        static let topPadding: CGFloat = 10
        static let completedSegmentIncreasedOpacity: Double = 0.7
        static let completedSegmentOpacity: Double = 0.4
        static let pendingSegmentIncreasedOpacity: Double = 0.55
        static let pendingSegmentOpacity: Double = 0.25
    }

    enum Footer {
        static let contentSpacing: CGFloat = 8
        static let buttonLabelSpacing: CGFloat = 4
        static let disabledBackOpacity: Double = 0.4
        static let instructionOpacity: Double = 0.6
        static let minimumContentSpacing: CGFloat = 8
        static let nextButtonHorizontalPadding: CGFloat = 12
        static let nextButtonVerticalPadding: CGFloat = 6
        static let nextButtonDisabledOpacity: Double = 0.5
        static let topPadding: CGFloat = 2
        static let bottomPadding: CGFloat = 12
    }

    enum CollapsedBanner {
        static let countBadgeHorizontalPadding: CGFloat = 7
        static let countBadgeVerticalPadding: CGFloat = 1
        static let badgeFillOpacity: Double = 0.12
        static let countBadgeBorderOpacity: Double = 0.35
        static let countBadgeBorderWidth: CGFloat = 1
        static let minimumContentSpacing: CGFloat = 8
        static let verticalPadding: CGFloat = 9
        static let dismissButtonTrailingPadding: CGFloat = 8
    }

    enum DismissButton {
        static let horizontalPadding: CGFloat = 6
        static let verticalPadding: CGFloat = 4
        static let disabledOpacity: Double = 0.5
    }
}
