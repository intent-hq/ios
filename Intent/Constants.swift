import Foundation
import SwiftUI
import UIKit

enum Constants {
    enum Accessibility {
        static let minimumTapTarget: CGFloat = 44
    }

    enum Conversation {
        enum Attribution {
            static let spacing: CGFloat = 6
            static let expansionAnimationDuration: Double = 0.2
        }

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

        enum AgentWaiting {
            static let progressScale: CGFloat = 0.7
            static let fallbackProgressScale: CGFloat = 0.6
            static let fallbackAgentIdMaximumLength = 12
            static let activityRefreshThrottle: TimeInterval = 3
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

        enum Message {
            static let contextPreviewLineLimit = 25
            static let contextPreviewMaximumWidth: CGFloat = 320
        }

        enum Composer {
            static let minimumTextViewHeight = Constants.Accessibility.minimumTapTarget
            static let maximumTextViewHeight: CGFloat = 120
            static let maximumImageSelectionCount = 5
            static let draftSaveDebounceMilliseconds = 500
            static let imageCompressionQuality: CGFloat = 0.8
            static let pendingImageSide: CGFloat = 56
            static let pendingFileMaximumWidth: CGFloat = 200
            static let refocusDelay: Double = 0.05
            static let textContainerInset: CGFloat = 4
        }

        enum Column {
            static let chromeAnimationDuration: Double = 0.25
        }

        enum Sending {
            static let messageAppendSpringResponse: Double = 0.35
            static let messageAppendSpringDamping: Double = 0.7
            static let stateTransitionAnimationDuration: Double = 0.2
        }

        enum Transcript {
            static let atBottomThreshold: CGFloat = 50
            static let initialScrollDelay: Double = 0.1
            static let initialScrollSettleDelay: Double = 0.2
            static let dividerProbeDelay: Double = 0.15
            static let scrollDebounceMilliseconds = 100
            static let scrollAnimationDuration: Double = 0.2
            static let goToEndVisibilityAnimationDuration: Double = 0.2
            static let scrollCompletionMilliseconds = 300
        }

        enum QuestionWizard {
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
        }

        enum ResponseGroup {
            static let expansionAnimationDuration: Double = 0.25
            static let contentIndent: CGFloat = 18
            static let railInset: CGFloat = 8
            static let railWidth: CGFloat = 1
            static let collapsedMaximumHeight: CGFloat = 100
            static let collapsedFadeHeight: CGFloat = 24
        }

        enum ToolCall {
            static let expansionAnimationDuration: Double = 0.2
            static let outputCharacterLimit = 2_000
            static let outputMaximumHeight: CGFloat = 200
        }

        enum ToolClassifier {
            static let titleMaximumLength = 80
            static let commandMaximumLength = 80
            static let standardSubjectMaximumLength = 60
            static let compactSubjectMaximumLength = 50
            static let agentNameMaximumLength = 30
            static let taskMaximumLength = 40
            static let noteTitleMaximumLength = 25
            static let commitMessageMaximumLength = 40
            static let fallbackTitleMaximumLength = 120
            static let proseMinimumWordCount = 3
        }

        enum ContextMention {
            static let titleMaximumLength = 30
        }

        enum AttentionRequest {
            static let reasonLineLimit = 6
        }

        enum QueuedMessage {
            static let actionButtonSide: CGFloat = 36
        }

        enum CodeBlock {
            static let copyConfirmationDuration: Double = 2
        }

        enum ImageLightbox {
            static let springAnimationDuration: Double = 0.3
        }

        enum ImageThumbnail {
            static let cornerRadius: CGFloat = 8
            static let borderWidth: CGFloat = 0.5
        }

        enum CopyContextMenu {
            static let minimumInteractiveAlpha: CGFloat = 0.01
            static let minimumInvertibleDeterminant: CGFloat = 1e-6
        }

        enum EventWake {
            static let countLabelRange = 2..<5
        }
    }

    enum AppCoordination {
        static let reconnectOverlayTimeout: Duration = .seconds(5)
    }

    enum Connection {
        static let logPreviewCharacterLimit = 100
        static let reconnectBackoffExponentCap = 5
        static let reconnectBackoffMaximum: Double = 30
    }

    enum WebSocket {
        static let pingTimeout: Duration = .seconds(30)
        nonisolated static let closeCancellationGracePeriod: TimeInterval = 2
    }

    enum AgentStore {
        static let fetchDebounce: Duration = .milliseconds(300)
    }

    enum Notification {
        static let presentationSpringResponse: Double = 0.4
        static let presentationSpringDamping: Double = 0.85
        static let displayDuration: Duration = .seconds(4)
        static let dismissalAnimationDuration: Double = 0.25
    }

    enum Note {
        static let previewCharacterLimit = 120
    }

    enum Root {
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

    enum Connecting {
        static let horizontalPadding: CGFloat = 20
        static let verticalPadding: CGFloat = 12
        static let bottomPadding: CGFloat = 24
        static let workspaceLoadTimeout: TimeInterval = 5
        static let workspacePollInterval: Duration = .milliseconds(100)
    }

    enum Disconnected {
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

    enum ConnectionFailure {
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
        static let retryBackoffExponentCap = 5
        static let retryBackoffMaximum: Double = 30
    }

    enum AgentAvatar {
        enum FallbackSelection {
            static let hashShift = 5
            static let multiplier: Double = 1_103_515_245
            static let increment: Double = 12_345
            static let modulus: Double = 4_294_967_296
            static let mask: UInt32 = 0x7FFF_FFFF
            static let normalizationDivisor: UInt32 = 0x8000_0000
        }

        static let artSizeRatio: CGFloat = 0.8
        static let cornerRadiusRatio: CGFloat = 0.3
        nonisolated static let referenceArtSize: CGFloat = 16
        static let referenceStrokeWidth: CGFloat = 1.33
        static let activeStrokeWidth: CGFloat = 1.5
        static let pulseAnimationDuration: Double = 1
    }

    enum AgentRow {
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
        static let maximumHeaderAvatars = 5
        static let headerAvatarSize: CGFloat = 16
        static let delegatedLeadingPadding: CGFloat = 40
        static let delegatedVerticalPadding: CGFloat = 4
        static let backgroundVerticalPadding: CGFloat = 8
    }

    enum WorkspaceRow {
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
    }

    enum RelativeTime {
        static let minute: TimeInterval = 60
        static let hour: TimeInterval = 3_600
        static let day: TimeInterval = 86_400
        static let week: TimeInterval = 604_800
    }

    enum WorkspaceList {
        static let pickerHorizontalPadding: CGFloat = 16
        static let pickerVerticalPadding: CGFloat = 8
        static let emptyStateSpacing: CGFloat = 12
        static let bottomContentMargin: CGFloat = 60
        static let sidebarRowInset: CGFloat = 8
        static let sidebarSectionSpacing: CGFloat = 6
        static let sidebarSectionAvatarSize: CGFloat = 16
        static let sidebarTopContentMargin: CGFloat = 4
    }

    enum WorkspaceSearch {
        static let contentSpacing: CGFloat = 8
        static let horizontalPadding: CGFloat = 12
        static let verticalPadding: CGFloat = 10
        static let cornerRadius: CGFloat = 12
        static let borderOpacity: Double = 0.2
        static let borderWidth: CGFloat = 0.5
        static let bottomPadding: CGFloat = 8
        static let focusAnimationDuration: Double = 0.2
    }

    enum WorkspaceDetail {
        static let titleLineLimit = 2
        static let horizontalPadding: CGFloat = 16
        static let regularTitleTopPadding: CGFloat = 4
        static let titleBottomPadding: CGFloat = 4
        static let progressSectionSpacing: CGFloat = 4
        static let progressSpacing: CGFloat = 1
        static let progressCornerRadius: CGFloat = 2
        static let remainingProgressOpacity: Double = 0.2
        static let progressHeight: CGFloat = 4
        static let progressBottomPadding: CGFloat = 8
        static let emptyStateSpacing: CGFloat = 12
        static let tabVerticalPadding: CGFloat = 8
    }

    enum ModalPicker {
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
        static let rowDescriptionLineLimit = 2
    }

    enum CreateWorkspace {
        static let errorStateSpacing: CGFloat = 12
        static let errorStatePadding: CGFloat = 24
        static let branchBadgeHorizontalPadding: CGFloat = 6
        static let branchBadgeVerticalPadding: CGFloat = 2
        static let branchBadgeOpacity: Double = 0.15
        static let branchRowVerticalPadding: CGFloat = 2
        static let messageLineCountRange = 3...6
        static let branchSearchDebounceNanoseconds: UInt64 = 300_000_000
    }

    enum GitHubRepoPicker {
        static let rowSpacing: CGFloat = 12
        static let rowTextSpacing: CGFloat = 4
        static let rowVerticalPadding: CGFloat = 4
        static let emptyStateSpacing: CGFloat = 12
        static let emptyStateHorizontalPadding: CGFloat = 24
        static let searchDebounce: Duration = .milliseconds(300)
    }

    enum RepoOwnerAvatar {
        static let requestPixelSize = 64
        static let borderOpacity: Double = 0.2
        static let borderWidth: CGFloat = 1
        static let fallbackScale: CGFloat = 0.5
    }

    enum ManualTokenEntry {
        static let contentSpacing: CGFloat = 24
        static let headerSpacing: CGFloat = 8
        static let headerTopPadding: CGFloat = 32
        static let formSpacing: CGFloat = 16
        static let fieldSpacing: CGFloat = 4
        static let horizontalPadding: CGFloat = 24
        static let progressSpacing: CGFloat = 8
    }

    enum Pairing {
        static let contentSpacing: CGFloat = 32
        static let headerSpacing: CGFloat = 8
        static let logoSize: CGFloat = 40
        static let descriptionHorizontalPadding: CGFloat = 32
        static let optionsSpacing: CGFloat = 12
        static let optionsHorizontalPadding: CGFloat = 24
        static let optionSpacing: CGFloat = 16
        static let optionIconWidth: CGFloat = 32
        static let optionTextSpacing: CGFloat = 2
        static let optionPadding: CGFloat = 16
        static let optionCornerRadius: CGFloat = 12
        static let optionBorderWidth: CGFloat = 1
    }

    enum Settings {
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

    enum Connections {
        static let rowSpacing: CGFloat = 12
        static let rowTextSpacing: CGFloat = 2
        static let statusSpacing: CGFloat = 4
        static let statusDotSize: CGFloat = 8
    }

    enum Notes {
        enum Content {
            static let segmentSpacing: CGFloat = 8
            static let maximumIndentColumns = 12
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

        enum Detail {
            static let contentSpacing: CGFloat = 12
            static let tagSpacing: CGFloat = 4
            static let tagHorizontalPadding: CGFloat = 8
            static let tagVerticalPadding: CGFloat = 3
            static let tagCornerRadius: CGFloat = 6
            static let contentPadding: CGFloat = 16
        }

        enum List {
            static let emptyStateSpacing: CGFloat = 12
            static let horizontalPadding: CGFloat = 16
            static let expansionAnimationDuration: Double = 0.2
            static let indentationWidth: CGFloat = 24
            static let rowSpacing: CGFloat = 6
            static let disclosureSize: CGFloat = 28
            static let contentSpacing: CGFloat = 4
            static let titleSpacing: CGFloat = 2
            static let maximumTagCount = 3
            static let tagHorizontalPadding: CGFloat = 6
            static let tagVerticalPadding: CGFloat = 2
            static let tagCornerRadius: CGFloat = 4
            static let rootVerticalPadding: CGFloat = 10
            static let nestedVerticalPadding: CGFloat = 9
            static let horizontalRowPadding: CGFloat = 4
        }

        enum Metadata {
            static let sectionSpacing: CGFloat = 6
            static let rowSpacing: CGFloat = 8
            static let labelWidth: CGFloat = 110
            static let verticalPadding: CGFloat = 3
            static let chipStackSpacing: CGFloat = 4
            static let chipHorizontalPadding: CGFloat = 8
            static let chipCornerRadius: CGFloat = 6
            static let fallbackIdMaximumLength = 14
            static let statusIconSize: CGFloat = 16
            static let relationIconSize: CGFloat = 14
            static let relationSpacing: CGFloat = 6
            static let warningBackgroundOpacity: Double = 0.12
            static let mutedBackgroundOpacity: Double = 0.4
        }
    }

    enum Toast {
        static let contentSpacing: CGFloat = 12
        static let textSpacing: CGFloat = 2
        static let horizontalPadding: CGFloat = 16
        static let verticalPadding: CGFloat = 12
        static let cornerRadius: CGFloat = 14
        static let shadowOpacity: Double = 0.15
        static let shadowRadius: CGFloat = 12
        static let shadowYOffset: CGFloat = 4
        static let outerHorizontalPadding: CGFloat = 12
        static let dismissalDragThreshold: CGFloat = -40
        static let resetSpringResponse: Double = 0.3
        static let resetSpringDamping: Double = 0.7
    }

    enum QRScanner {
        static let unavailableMessagePadding: CGFloat = 24
        static let statusSpacing: CGFloat = 8
        static let statusPadding: CGFloat = 20
        static let statusBackgroundOpacity: Double = 0.7
        static let statusCornerRadius: CGFloat = 12
        static let statusBottomPadding: CGFloat = 60
        static let errorDisplayDuration: Duration = .seconds(3)
        static let duplicateScanResetDelay: Duration = .seconds(3)
    }

    enum Loading {
        static let phaseDuration: Duration = .milliseconds(1_200)
    }

    enum Splash {
        enum Random {
            static let multiplier: UInt32 = 1_664_525
            static let increment: UInt32 = 1_013_904_223
            static let normalizationDivisor: Double = 4_294_967_296
        }

        static let minimumColumns = 4
        static let targetCellWidth: Double = 150
        static let minimumRows = 6
        static let routeCoverageWeight: Double = 1_000
        static let targetRouteCoverage: Double = 0.65
        static let firstAmbientDelay: Double = 700
        static let ambientStagger: Double = 0.7
        static let minimumAmbientInterval: Double = 1_100
        static let ambientIntervalRange: Double = 1_500
        static let repeatFlipCooldown: Double = 350
        static let interactiveStagger: Double = 0.45
    }

    enum Colors {
        enum Theme {
            static func background(for scheme: ColorScheme) -> Color {
                Colors.resolvedColor(UIColor(resource: .themeBackground), for: scheme)
            }

            static func foreground(for scheme: ColorScheme) -> Color {
                Colors.resolvedColor(UIColor(resource: .themeForeground), for: scheme)
            }

            static func card(for scheme: ColorScheme) -> Color {
                Colors.resolvedColor(UIColor(resource: .themeCard), for: scheme)
            }

            static func sidebar(for scheme: ColorScheme) -> Color {
                Colors.resolvedColor(UIColor(resource: .themeSidebar), for: scheme)
            }

            static func primary(for scheme: ColorScheme) -> Color {
                Colors.resolvedColor(UIColor(resource: .themePrimary), for: scheme)
            }

            static func muted(for scheme: ColorScheme) -> Color {
                Colors.resolvedColor(UIColor(resource: .themeMuted), for: scheme)
            }

            static func mutedForeground(
                for scheme: ColorScheme, contrast: ColorSchemeContrast = .standard
            ) -> Color {
                if contrast == .increased {
                    return foreground(for: scheme).opacity(0.9)
                }
                return Colors.resolvedColor(UIColor(resource: .themeMutedForeground), for: scheme)
            }

            static func border(
                for scheme: ColorScheme, contrast: ColorSchemeContrast = .standard
            ) -> Color {
                if contrast == .increased {
                    return foreground(for: scheme).opacity(0.55)
                }
                return Colors.resolvedColor(UIColor(resource: .themeBorder), for: scheme)
            }

            static func destructive(for scheme: ColorScheme) -> Color {
                Colors.resolvedColor(UIColor(resource: .themeDestructive), for: scheme)
            }
        }

        enum WorkspaceStatus {
            static let failed = Color(.workspaceStatusFailed)
            static let blocked = Color(.workspaceStatusBlocked)
            static let needsAttention = Color(.workspaceStatusNeedsAttention)
            static let idle = Color(.workspaceStatusIdle)
            static let notStarted = Color(.workspaceStatusNotStarted)
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
            static let glyph = Color(.agentAvatarGlyph)
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
                Colors.resolvedColor(UIColor(resource: .markdownInlineCodeForeground), for: scheme)
            }

            static func inlineCodeBackground(for scheme: ColorScheme) -> Color {
                Colors.resolvedColor(UIColor(resource: .markdownInlineCodeBackground), for: scheme)
            }

            static func codeBlockBackground(for scheme: ColorScheme) -> Color {
                Colors.resolvedColor(UIColor(resource: .markdownCodeBlockBackground), for: scheme)
            }
        }

        enum CodeBlock {
            static let background = Color(.codeBlockBackground)
            static let secondaryLabel = Color(.codeBlockSecondaryLabel)
            static let action = Color(.codeBlockAction)
            static let foreground = Color(.codeBlockForeground)
        }

        private static func resolvedColor(_ color: UIColor, for scheme: ColorScheme) -> Color {
            let style: UIUserInterfaceStyle = scheme == .dark ? .dark : .light
            let traits = UITraitCollection(userInterfaceStyle: style)
            return Color(uiColor: color.resolvedColor(with: traits))
        }
    }
}