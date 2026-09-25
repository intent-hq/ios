/// A coverage register, not an exhaustive control-flow proof.
/// Partial families remain in exported pendingFamilies until all owners land.
/// These static source/test names are for repository checks only, never export.
nonisolated enum DiagnosticCoverage {
    enum Status: String, Codable, Sendable {
        case instrumented, partial, pending
    }

    struct Entry: Sendable {
        let family: DiagnosticFamily
        let status: Status
        let source: String
        let test: String
    }

    static let version = 1
    static let entries: [Entry] = DiagnosticFamily.allCases.map { family in
        let ownership = owner(for: family)
        return Entry(family: family, status: status(for: family), source: ownership.source, test: ownership.test)
    }

    /// No identifiers, paths or test names are included in report metadata.
    static var pendingFamilies: [DiagnosticFamily] { entries.filter { $0.status != .instrumented }.map(\.family) }

    private static func status(for family: DiagnosticFamily) -> Status {
        switch family {
        case .app, .connection, .network, .scanner, .trust: .instrumented
        case .pairing, .protocolHandling, .subscription, .other: .partial
        default: .pending
        }
    }

    /// Reviewed boundary ownership, including intentional exclusions. Static
    /// source names/explanations are documentation, never serialized metadata.
    static let transportBoundaries: [String] = [
        "IntentApp.init / BackendWindowSession: LifecycleDiagnostics; duplicate scene phases ignored",
        "NetworkAvailability: accepted status changes; stale/repeated callbacks and lease teardown are benign",
        "ConnectionManager.connect: attempt start/outcome, missing pin, failed race, supersession cancellation",
        "ConnectionHostRacing.settleCandidates: candidate trust/transport failures; cancelled losers benign",
        "ConnectionHostRacing.makeDrain: late pin rejections recovered by winner; generic cancelled-loser fallout benign",
        "ConnectionManagerRecovery: active socket/endpoint/tunnel loss, retry/exhaustion/recovered outcomes",
        "ConnectionManagerHeartbeat: failed probe owns connection loss; healthy pongs and stopped tasks benign",
        "WebSocketConnection: typed NWError captured before flattening; manager owns reporting",
        "WebSocketConnectionSecurity: trust/URL errors propagate to race/connect owner; no fingerprint export",
        "ConnectionManagerRequests: local encode/not-connected/timeout and remote RPC errors carry receipts",
        "Request propagation: feature TaskLocal owner or other.request fallback; receipt prevents duplicate catch logging",
        "Request teardown: failAllPending receipts suppressed; connection transition is the outage owner",
        "Global subscription: request owns retry/exhaustion; successful acknowledgment owns ready/recovered",
        "Protocol: malformed complete JSON, malformed subscription push and message assembly recorded",
        "Protocol exclusions: partial frames, unknown notifications, late responses and healthy payloads benign",
        "CertFingerprintProbe.probeFirst: failed candidates and recovered fallback; PairingFlow owns final outcome",
        "PairingFlow/manual: input/probe/connect/save phases; persistence task owns detailed save/refresh failure",
        "QR scanner: capability/permission/start/delegate failure; duplicate QR and inactive callbacks benign",
        "AppCoordinatorRouting: malformed pair links recorded; unrelated URLs benign",
        "Remaining: feature subscriptions/required responses and detailed persistence owned by later producer tasks",
        "Unobservable: native kills, Tailcat internals and abrupt termination of queued diagnostics"
    ]

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
        case .app: ("App/IntentApp.swift", "PairingLifecycleDiagnosticTests.swift")
        case .attachment: ("Services/AttachmentUploadService.swift", "AttachmentUploadServiceTests.swift")
        case .background: ("Utils/BackgroundTaskManager.swift", "BackgroundTaskManagerTests.swift")
        case .connection: ("Services/ConnectionManager.swift", "TransportDiagnosticTests.swift")
        case .conversation: ("Services/ConversationCommands.swift", "ConversationStoreQueueTests.swift")
        case .dictation: ("Services/SpeechDictationController.swift", "DictationTranscriptTests.swift")
        case .github: ("Services/GitHubRepoStore.swift", "GitHubRepoStoreTests.swift")
        case .hook: ("Services/BackgroundHookStore.swift", "BackgroundHookStoreTests.swift")
        case .image: ("Services/RemoteImageLoader.swift", "RemoteImageLoaderTests.swift")
        case .link: ("Views/Conversation/Content/ContextMentionChipView.swift", "DiagnosticCoverageTests.swift")
        case .network: ("Services/NetworkAvailability.swift", "PairingLifecycleDiagnosticTests.swift")
        case .note: ("Services/NoteStore.swift", "NoteStoreIntegrationTests.swift")
        case .notification: ("Utils/LocalNotificationService.swift", "LocalNotificationServiceTests.swift")
        case .other: ("Utils/DiagnosticOperation.swift", "DiagnosticCoverageTests.swift")
        case .pairing: ("Services/PairingFlow.swift", "PairingLifecycleDiagnosticTests.swift")
        case .persistence: ("PersistenceManager.swift", "PersistenceManagerTests.swift")
        case .prMonitor: ("Services/MonitoredPrStore.swift", "MonitoredPrStoreTests.swift")
        case .protocolHandling: ("Services/WebSocketMessageAssembler.swift", "TransportDiagnosticTests.swift")
        case .provider: ("Services/CreationOptionsStore.swift", "CreationOptionsStoreTests.swift")
        case .scanner: ("Views/Onboarding/QRScannerView.swift", "PairingLifecycleDiagnosticTests.swift")
        case .subscription: ("Services/ConnectionSubscriptionRouter.swift", "TransportDiagnosticTests.swift")
        case .task: ("Services/TaskStore.swift", "TaskStoreIntegrationTests.swift")
        case .trust: ("Services/CertFingerprintProbe.swift", "TransportDiagnosticTests.swift")
        case .userInterface: ("Views/Conversation/Transcript/ConversationScrollViewSupport.swift", "DiagnosticCoverageTests.swift")
        case .workspace: ("Services/WorkspaceStore.swift", "WorkspaceStoreTests.swift")
        }
    }
}
