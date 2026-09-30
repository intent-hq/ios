import Foundation

/// This channel is intentionally separate from AppLog: no message, identifier,
/// path, dictionary or foreign error can be supplied to a persisted event.
nonisolated struct DiagnosticEvent: Codable, Equatable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case appSessionStarted = "app.session_started"
        case appSceneChanged = "app.scene_changed"
        case connectionAttempt = "connection.attempt"
        case connectionTransition = "connection.transition"
        case networkAvailabilityChanged = "network.availability_changed"
        case operationFailed = "operation.failed"
        case pairingPhase = "pairing.phase"
        case persistenceFailed = "persistence.failed"
        case subscriptionRecovery = "subscription.recovery"
        case trustRejected = "trust.rejected"
    }

    enum Stage: String, Codable, CaseIterable, Sendable {
        case active, cleanup, connect, decode, input, permission, placement, probe, read, request, response
        case save, scanner, start
        case trustConfirmation = "trust_confirmation"
        case tunnelEstablish = "tunnel_establish"
        case tunnelHandshake = "tunnel_handshake"
        case write
    }

    enum Outcome: String, Codable, CaseIterable, Sendable {
        case awaitingConfirmation = "awaiting_confirmation"
        case bestEffort = "best_effort"
        case cancelled, changed, exhausted, failed
        case fallbackPending = "fallback_pending"
        case recovered, retrying, started, succeeded
    }

    enum Effect: String, Codable, CaseIterable, Sendable {
        case attemptBlocked = "attempt_blocked"
        case candidateRejected = "candidate_rejected"
        case none
        case notSent = "not_sent"
        case partial
        case remoteRejected = "remote_rejected"
        case unknown
    }

    enum Context: String, Codable, CaseIterable, Sendable {
        case active
        case automaticRecovery = "automatic_recovery"
        case background, connected, connecting, direct, disconnected
        case endpointPathLost = "endpoint_path_lost"
        case explicitDisconnect = "explicit_disconnect"
        case failureScreenRetry = "failure_screen_retry"
        case heartbeatFailure = "heartbeat_failure"
        case inactive, lan
        case localNetworkDenied = "local_network_denied"
        case malformedPush = "malformed_push"
        case manualRetry = "manual_retry"
        case none, pairing, reconnecting
        case requiresConnection = "requires_connection"
        case satisfied, saved
        case sequenceGap = "sequence_gap"
        case snapshotTimeout = "snapshot_timeout"
        case socketFailure = "socket_failure"
        case stopped, tunnel
        case tunnelUnderlayLost = "tunnel_underlay_lost"
        case unavailable, unknown, unsatisfied
    }

    let kind: Kind
    let operation: DiagnosticOperation
    let site: DiagnosticSite
    let stage: Stage
    let outcome: Outcome
    let failure: DiagnosticFailure
    let effect: Effect
    let context: Context

    init(
        kind: Kind,
        operation: DiagnosticOperation,
        site: DiagnosticSite,
        stage: Stage,
        outcome: Outcome,
        failure: DiagnosticFailure = .none,
        effect: Effect = .none,
        context: Context = .none
    ) {
        self.kind = kind
        self.operation = operation
        self.site = site
        self.stage = stage
        self.outcome = outcome
        self.failure = failure
        self.effect = effect
        self.context = context
    }

    /// Consecutive repetition only. Recovery, terminal exhaustion, cancellation
    /// and state changes always get their own record, even if otherwise equal.
    var canSummarize: Bool {
        failure != .none && [.bestEffort, .failed, .fallbackPending, .retrying].contains(outcome)
    }
}

nonisolated enum DiagnosticSite: String, Codable, CaseIterable, Sendable {
    case agentStore = "agent_store"
    case appCoordinator = "app_coordinator"
    case attachmentPipeline = "attachment_pipeline"
    case attachmentUpload = "attachment_upload"
    case backgroundTask = "background_task"
    case connectionManager = "connection_manager"
    case conversationCommands = "conversation_commands"
    case conversationTranscript = "conversation_transcript"
    case conversationViewModel = "conversation_view_model"
    case creationOptions = "creation_options"
    case dictation
    case githubStore = "github_store"
    case hookStore = "hook_store"
    case imageLoader = "image_loader"
    case keychain, link
    case networkAvailability = "network_availability"
    case noteStore = "note_store"
    case notificationAudio = "notification_audio"
    case notificationService = "notification_service"
    case pairing, persistence, photos
    case prMonitorStore = "pr_monitor_store"
    case providerOptions = "provider_options"
    case scanner
    case subscriptionRouter = "subscription_router"
    case syncedRegistry = "synced_registry"
    case taskStore = "task_store"
    case transcriptScroll = "transcript_scroll"
    case trustProbe = "trust_probe"
    case webSocket = "web_socket"
    case workspaceStore = "workspace_store"
}
