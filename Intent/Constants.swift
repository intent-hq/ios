import Foundation
import SwiftUI
import UIKit

enum Constants {
    enum Accessibility {
        static let minimumTapTarget: CGFloat = 44
    }

    enum Conversation {
        enum Attribution {}

        enum AgentWaiting {
            static let fallbackAgentIdMaximumLength = 12
            static let activityRefreshThrottle: TimeInterval = 3
        }

        enum Message {
            static let contextPreviewLineLimit = 25
        }

        enum Composer {
            static let maximumImageSelectionCount = 5
            static let draftSaveDebounceMilliseconds = 500
            static let imageCompressionQuality: CGFloat = 0.8
            static let refocusDelay: Double = 0.05
        }

        enum Column {}

        enum Sending {}

        enum Transcript {
            static let atBottomThreshold: CGFloat = 50
            static let initialScrollDelay: Double = 0.1
            /// Longest the entry scroll waits for the transcript UIScrollView
            /// to be found before scrolling anyway.
            static let initialScrollHostingTimeout: Double = 1.0
            static let initialScrollSettleDelay: Double = 0.2
            static let dividerProbeDelay: Double = 0.15
            static let scrollDebounceMilliseconds = 100
            static let scrollCompletionMilliseconds = 300
            /// Minimum spacing between follow-to-bottom scrolls issued for
            /// streaming deltas. The bottom-anchored ScrollView keeps a pinned
            /// viewport on the bottom as content grows, so deltas only re-pin a
            /// viewport that drifted, and never more than once per interval.
            static let streamingFollowMinimumInterval: TimeInterval = 0.5
            /// Distance from the bottom (points) at or under which the viewport
            /// counts as pinned and a streaming delta issues no scroll at all.
            static let streamingFollowDriftTolerance: CGFloat = 1
        }

        enum QuestionWizard {}

        enum ResponseGroup {}

        enum ToolCall {
            static let outputCharacterLimit = 2_000
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

        enum CodeBlock {
            static let copyConfirmationDuration: Double = 2
        }

        enum ImageLightbox {}

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
        static let displayDuration: Duration = .seconds(4)
    }

    enum Note {
        static let previewCharacterLimit = 120
    }

    enum Root {}

    enum Connecting {
        static let workspaceLoadTimeout: TimeInterval = 5
        static let workspacePollInterval: Duration = .milliseconds(100)
    }

    enum Disconnected {}

    enum ConnectionFailure {
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

    }

    enum AgentRow {
        static let maximumHeaderAvatars = 5
    }

    enum WorkspaceRow {}

    enum RelativeTime {
        static let minute: TimeInterval = 60
        static let hour: TimeInterval = 3_600
        static let day: TimeInterval = 86_400
        static let week: TimeInterval = 604_800
    }

    enum WorkspaceList {}

    enum WorkspaceSearch {}

    enum WorkspaceDetail {
        static let titleLineLimit = 2
    }

    enum ModalPicker {
        static let rowDescriptionLineLimit = 2
    }

    enum CreateWorkspace {
        static let messageLineCountRange = 3...6
        static let branchSearchDebounce: Duration = .milliseconds(300)
    }

    enum GitHubRepoPicker {
        static let searchDebounce: Duration = .milliseconds(300)
    }

    enum RepoOwnerAvatar {
        static let requestPixelSize = 64
    }

    enum ManualTokenEntry {}

    enum Pairing {}

    enum Settings {}

    enum Connections {}

    enum Notes {
        enum Content {
            static let maximumIndentColumns = 12
        }

        enum Detail {}

        enum List {
            static let maximumTagCount = 3
        }

        enum Metadata {
            static let fallbackIdMaximumLength = 14
        }
    }

    enum Toast {
        static let dismissalDragThreshold: CGFloat = -40
    }

    enum QRScanner {
        static let errorDisplayDuration: Duration = .seconds(3)
        static let duplicateScanResetDelay: Duration = .seconds(3)
    }

    enum Loading {}

    enum Splash {}

}
