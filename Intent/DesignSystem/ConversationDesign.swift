import SwiftUI

extension Constants.Conversation {
    /// Opt-in workspace-agent styling from the approved 402pt Figma frames.
    /// Existing conversation constants stay unchanged for Assistant and other callers.
    /// Heights are visual baselines, not text caps; preserve Dynamic Type and platform hit targets.
    enum Design {
        static let horizontalInset: CGFloat = 24
        static let sectionSpacing: CGFloat = 32
        static let cornerRadius: CGFloat = 20
        static let innerCornerRadius: CGFloat = 16
        static let iconSize: CGFloat = 24
        static let toolIconSize: CGFloat = 20
        static let smallIconSize: CGFloat = 16
        static let minimumTapTarget = Constants.Accessibility.minimumTapTarget
    }
}

extension Constants.Conversation.Design {
    enum Header {
        static let controlSize: CGFloat = 48
        static let verticalPadding: CGFloat = 8
        static let titleSpacing: CGFloat = 8
        static let fadeHeight: CGFloat = 32
    }

    enum Column {
        // Reserve a usable transcript band from the native keyboard-safe column.
        // The remaining space, minus measured footer content, belongs to questions.
        static let transcriptHeightFraction: CGFloat = 0.25
    }

    enum Transcript {
        static let bubblePadding: CGFloat = 20
        // Adaptive implementation policy; accessibility text uses the full available width.
        nonisolated static let bubbleMaximumWidthFraction: CGFloat = 0.75
        static let toolRowSpacing: CGFloat = 12
        static let toolLabelSpacing: CGFloat = 16
        static let disclosureSpacing: CGFloat = 12
        static let expandedContentSpacing: CGFloat = 20
        static let expandedContentIndent = Constants.Conversation.Design.toolIconSize + Self.toolLabelSpacing
    }

    enum Watcher {
        static let sectionSpacing: CGFloat = 20
        static let rowSpacing: CGFloat = 12
        static let attributionSpacing: CGFloat = 4
    }

    enum Composer {
        static let minimumHeight: CGFloat = 56
        static let leadingPadding: CGFloat = 20
        static let trailingPadding: CGFloat = 16
        static let activeTrailingPadding: CGFloat = 8
        static let keyboardHorizontalInset: CGFloat = 8
        static let keyboardBottomSpacing: CGFloat = 8
        static let activeCornerRadius: CGFloat = 24
        static let controlSpacing: CGFloat = 16
        static let actionWidth: CGFloat = 48
        static let actionHeight: CGFloat = 40
        // Figma's stop control is a rounded rectangle, not the larger bundled StopFill glyph.
        static let stopSide: CGFloat = 18
        static let stopCornerRadius: CGFloat = 4
    }

    enum Status {
        static let minimumHeight: CGFloat = 32
        static let leadingPadding: CGFloat = 16
        static let trailingPadding: CGFloat = 4
        static let iconSpacing: CGFloat = 12
        static let composerSpacing: CGFloat = 8
        static let goToEndLeadingPadding: CGFloat = 12
        static let goToEndTrailingPadding: CGFloat = 16
        static let goToEndIconSpacing: CGFloat = 10
        static let goToEndIconOpacity: Double = 0.3
    }

    enum Queue {
        static let topPadding: CGFloat = 24
        static let headerSpacing: CGFloat = 18
        static let headerTracking: CGFloat = 0.24
        static let textActionSpacing: CGFloat = 16
        static let iconSpacing: CGFloat = 20
        static let rowSpacing: CGFloat = 20
        static let composerSpacing: CGFloat = 24
        static let borderWidth: CGFloat = 1
        static let controlInset = (Constants.Conversation.Design.minimumTapTarget - Constants.Conversation.Design.iconSize) / 2
        static let actionSpacing = Self.iconSpacing - Self.controlInset * 2
    }

    enum Question {
        static let backdropBlur: CGFloat = 15
        static let backdropOpacity: Double = 0.3
        static let modalTopInset: CGFloat = 24
        static let horizontalPadding: CGFloat = 20
        static let topPadding: CGFloat = 24
        static let bottomPadding: CGFloat = 20
        static let contentSpacing: CGFloat = 24
        // Native line boxes include leading that Figma trims; preserve the visible text gap.
        static let titleSpacing: CGFloat = 8
        static let notificationSpacing: CGFloat = 32
        static let answerPadding: CGFloat = 24
        static let answerSpacing: CGFloat = 8
        static let answerTextSpacing: CGFloat = 8
        static let footerSpacing: CGFloat = 20
        static let buttonSpacing: CGFloat = 8
        static let buttonHorizontalPadding: CGFloat = 20
        static let buttonHeight: CGFloat = 40
        static let borderWidth: CGFloat = 1
    }

    enum Typography {
        // Figma tracking is percent of point size: Body S -1%; compact body and XS -2%.
        // Reuse Constants.Typography.bodyS/bodySEmphasized/bodyXS/bodyXSEmphasized via interFont.
        // Do not impose Figma's trimmed line-box heights on native text layout.
        static let bodyTracking: CGFloat = -0.16
        static let compactBodyTracking: CGFloat = -0.32
        static let smallTracking: CGFloat = -0.28
        static let status = Constants.Typography.subtextXXS.withFace(.medium)
    }
}
