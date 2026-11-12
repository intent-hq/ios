import SwiftUI
import UIKit

extension Constants {
    enum Colors {
        private static func resolvedColor(_ color: UIColor, for scheme: ColorScheme) -> Color {
            let style: UIUserInterfaceStyle = scheme == .dark ? .dark : .light
            let traits = UITraitCollection(userInterfaceStyle: style)
            return Color(uiColor: color.resolvedColor(with: traits))
        }
    }
}

extension Constants.Colors {
    enum WorkspaceStatus {
        static let failed = Color(.workspaceStatusFailed)
        static let blocked = Color(.workspaceStatusBlocked)
        static let needsAttention = Color(.workspaceStatusNeedsAttention)
        static let idle = Color(.workspaceStatusIdle)
        static let notStarted = Color(.workspaceStatusNotStarted)
        static let notStartedRing = Color(.workspaceStatusNotStartedRing)
        static let inProgress = Color(.workspaceStatusInProgress)
        static let complete = Color(.workspaceStatusComplete)
        static let prReady = Color(.workspaceStatusPrReady)
        static let prOpen = Color(.workspaceStatusPrOpen)
        static let prMerged = Color(.workspaceStatusPrMerged)
        static let unknown = Color(.workspaceStatusUnknown)
        static let unread = Color(.workspaceUnread)
    }

    enum AgentAvatar {
        static let surface = Color(.agentAvatarSurface)
        static let surfaceActive = Color(.agentAvatarSurfaceActive)
        static let surfaceAttention = Color(.agentAvatarSurfaceAttention)
        static let surfaceFailed = Color(.agentAvatarSurfaceFailed)
        static let surfaceWaiting = Color(.agentAvatarSurfaceWaiting)
        static let surfaceCompleted = Color(.agentAvatarSurfaceCompleted)
        static let glyph = Color(.agentAvatarGlyph)
        static let glyphCompleted = Color(.agentAvatarGlyphCompleted)
        static let activeStrokeWeak = Color(.agentAvatarActiveStrokeWeak)
        static let activeStrokeStrong = Color(.agentAvatarActiveStrokeStrong)
    }

    enum TaskStatus {
        static let neutral = Color(.taskStatusNeutral)
        static let warning = Color(.taskStatusWarning)
        static let blocked = Color(.taskStatusBlocked)
        static let inProgress = Color(.taskStatusInProgress)
        static let reviewRequired = Color(.taskStatusReviewRequired)
        static let completeStroke = Color(.taskStatusCompleteStroke)
        static let completeFill = Color(.taskStatusCompleteFill)
    }

    enum TaskProgress {
        static let track = Color(.taskStatusNeutral)
        static let complete = Color(.taskProgressComplete)
        static let inProgress = Color(.taskStatusInProgress)
    }

    enum Markdown {
        static func inlineCodeForeground(for scheme: ColorScheme) -> Color {
            Constants.Colors.resolvedColor(UIColor(resource: .markdownInlineCodeForeground), for: scheme)
        }

        static func inlineCodeBackground(for scheme: ColorScheme) -> Color {
            Constants.Colors.resolvedColor(UIColor(resource: .markdownInlineCodeBackground), for: scheme)
        }

        static func codeBlockBackground(for scheme: ColorScheme) -> Color {
            Constants.Colors.resolvedColor(UIColor(resource: .markdownCodeBlockBackground), for: scheme)
        }
    }

    enum CodeBlock {
        static let background = Color(.codeBlockBackground)
        static let secondaryLabel = Color(.codeBlockSecondaryLabel)
        static let action = Color(.codeBlockAction)
        static let foreground = Color(.codeBlockForeground)
    }
}
