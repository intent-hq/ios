/// A coverage register, NOT evidence that the producers have been installed.
/// Subsequent tasks replace pending entries with reviewed ownership + tests.
/// These static source/test names are for repository checks only, never export.
nonisolated enum DiagnosticCoverage {
    enum Status: String, Codable, Sendable {
        case pending
    }

    struct Entry: Sendable {
        let family: DiagnosticFamily
        let status: Status
        let source: String
        let test: String
    }

    static let version = 0
    static let entries: [Entry] = DiagnosticFamily.allCases.map { family in
        let ownership = owner(for: family)
        return Entry(family: family, status: .pending, source: ownership.source, test: ownership.test)
    }

    /// No identifiers, paths or test names are included in report metadata.
    static var pendingFamilies: [DiagnosticFamily] { entries.map(\.family) }

    enum Exclusion: String, Codable, CaseIterable, Sendable {
        case backendAuthoredFailures = "backend_authored_failures"
        case benignOptionalAbsence = "benign_optional_absence"
        case expectedCancellation = "expected_cancellation"
        case nativeCrashOrKill = "native_crash_or_kill"
        case notificationDelivery = "notification_delivery"
        case staleCompletion = "stale_completion"
        case userDefaultsDurability = "user_defaults_durability"
    }

    // Exhaustive inventory table, not branching application behavior.
    // swiftlint:disable:next cyclomatic_complexity
    private static func owner(for family: DiagnosticFamily) -> (source: String, test: String) {
        switch family {
        case .agent: ("Services/AgentStore.swift", "AgentStoreTests.swift")
        case .app: ("App/IntentApp.swift", "AppCoordinatorTests.swift")
        case .attachment: ("Services/AttachmentUploadService.swift", "AttachmentUploadServiceTests.swift")
        case .background: ("Utils/BackgroundTaskManager.swift", "BackgroundTaskManagerTests.swift")
        case .connection: ("Services/ConnectionManager.swift", "ConnectionManagerTests.swift")
        case .conversation: ("Services/ConversationCommands.swift", "ConversationStoreQueueTests.swift")
        case .dictation: ("Services/SpeechDictationController.swift", "DictationTranscriptTests.swift")
        case .github: ("Services/GitHubRepoStore.swift", "GitHubRepoStoreTests.swift")
        case .hook: ("Services/BackgroundHookStore.swift", "BackgroundHookStoreTests.swift")
        case .image: ("Services/RemoteImageLoader.swift", "RemoteImageLoaderTests.swift")
        case .link: ("Views/Conversation/Content/ContextMentionChipView.swift", "DiagnosticCoverageTests.swift")
        case .network: ("Services/NetworkAvailability.swift", "NetworkAvailabilityTests.swift")
        case .note: ("Services/NoteStore.swift", "NoteStoreIntegrationTests.swift")
        case .notification: ("Utils/LocalNotificationService.swift", "LocalNotificationServiceTests.swift")
        case .other: ("Utils/DiagnosticOperation.swift", "DiagnosticCoverageTests.swift")
        case .pairing: ("Services/PairingFlow.swift", "PairingFlowTests.swift")
        case .persistence: ("PersistenceManager.swift", "PersistenceManagerTests.swift")
        case .prMonitor: ("Services/MonitoredPrStore.swift", "MonitoredPrStoreTests.swift")
        case .protocolHandling: ("Services/WebSocketMessageAssembler.swift", "ConnectionManagerRequestTests.swift")
        case .provider: ("Services/CreationOptionsStore.swift", "CreationOptionsStoreTests.swift")
        case .scanner: ("Views/Onboarding/QRScannerView.swift", "DiagnosticCoverageTests.swift")
        case .subscription: ("Services/ConnectionSubscriptionRouter.swift", "ConnectionManagerSubscriptionTests.swift")
        case .task: ("Services/TaskStore.swift", "TaskStoreIntegrationTests.swift")
        case .trust: ("Services/CertFingerprintProbe.swift", "PairingFlowTests.swift")
        case .userInterface: ("Views/Conversation/Transcript/ConversationScrollViewSupport.swift", "DiagnosticCoverageTests.swift")
        case .workspace: ("Services/WorkspaceStore.swift", "WorkspaceStoreTests.swift")
        }
    }
}
