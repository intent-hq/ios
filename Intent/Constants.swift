import Foundation
import SwiftUI
import UIKit

enum ConversationConstants {
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

    enum QuestionWizard {}

    enum ResponseGroup {}

    enum ToolCall {
        static let outputCharacterLimit = 2000
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
        /// How many corrections a forced follow issues before giving up.
        static let followLandingRetries = 3
        /// Spacing between live geometry reads that verify a forced follow.
        static let followLandingPollMilliseconds = 50
        /// Longest a forced follow keeps verifying its landing.
        static let followLandingTimeoutMilliseconds = 3000
        /// Maximum distance from the bottom for a completed forced follow.
        static let followLandingTolerance: CGFloat = 1
        /// Minimum spacing between follow-to-bottom streaming scrolls.
        static let streamingFollowMinimumInterval: TimeInterval = 0.5
        /// Maximum pinned-viewport drift before a streaming follow scrolls.
        static let streamingFollowDriftTolerance: CGFloat = 1
        /// Delay before rechecking geometry that briefly reads past the end.
        static let pastEndSettleMilliseconds = 150
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

enum AgentAvatarConstants {
    enum FallbackSelection {
        static let hashShift = 5
        static let multiplier: Double = 1_103_515_245
        static let increment: Double = 12_345
        static let modulus: Double = 4_294_967_296
        static let mask: UInt32 = 0x7FFF_FFFF
        static let normalizationDivisor: UInt32 = 0x8000_0000
    }
}

enum NotesConstants {
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

enum Constants {
    enum Accessibility {
        static let minimumTapTarget: CGFloat = 44
    }

    typealias Conversation = ConversationConstants

    enum AppCoordination {
        private static let reconnectOverlayTimeoutSeconds = 5
        static let reconnectOverlayTimeout: Duration = .seconds(reconnectOverlayTimeoutSeconds)
    }

    enum Connection {
        nonisolated static let logPreviewCharacterLimit = 100
        static let reconnectBackoffExponentCap = 5
        static let reconnectBackoffMaximum: Double = 30
        /// An inbound frame whose off-main parse or MainActor dispatch takes
        /// longer than this (one 60 Hz frame) is logged as a slow frame.
        nonisolated static let slowFrameLogThreshold: TimeInterval = 0.016
    }

    enum WebSocket {
        private static let pingTimeoutSeconds = 30
        static let pingTimeout: Duration = .seconds(pingTimeoutSeconds)
        nonisolated static let closeCancellationGracePeriod: TimeInterval = 2
    }

    enum AgentStore {
        private static let fetchDebounceMilliseconds = 300
        static let fetchDebounce: Duration = .milliseconds(fetchDebounceMilliseconds)
    }

    enum Notification {
        private static let displayDurationSeconds = 4
        static let displayDuration: Duration = .seconds(displayDurationSeconds)
    }

    enum Note {
        static let previewCharacterLimit = 120
    }

    enum Root {}

    enum Connecting {
        private static let workspaceLoadTimeoutSeconds = 5
        static let workspaceLoadTimeout: Duration = .seconds(workspaceLoadTimeoutSeconds)
        static let workspacePollInterval: Duration = .milliseconds(100)
    }

    enum Disconnected {}

    enum ConnectionFailure {
        static let retryBackoffExponentCap = 5
        static let retryBackoffMaximum: Double = 30
    }

    typealias AgentAvatar = AgentAvatarConstants

    enum AgentRow {
        static let maximumHeaderAvatars = 5
    }

    enum WorkspaceRow {}

    enum RelativeTime {
        static let minute: TimeInterval = 60
        static let hour: TimeInterval = 3600
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
        private static let branchSearchDebounceMilliseconds = 300
        static let messageLineCountRange = 3...6
        static let branchSearchDebounce: Duration = .milliseconds(branchSearchDebounceMilliseconds)
    }

    enum GitHubRepoPicker {
        private static let searchDebounceMilliseconds = 300
        static let searchDebounce: Duration = .milliseconds(searchDebounceMilliseconds)
    }

    enum RepoOwnerAvatar {
        static let requestPixelSize = 64
    }

    enum ManualTokenEntry {}

    enum Pairing {}

    enum Settings {}

    enum Connections {}

    typealias Notes = NotesConstants

    enum Toast {
        static let dismissalDragThreshold: CGFloat = -40
    }

    enum QRScanner {
        private static let errorDisplayDurationSeconds = 3
        private static let duplicateScanResetDelaySeconds = 3
        static let errorDisplayDuration: Duration = .seconds(errorDisplayDurationSeconds)
        static let duplicateScanResetDelay: Duration = .seconds(duplicateScanResetDelaySeconds)
    }

    enum Loading {}

    enum Splash {}
}
