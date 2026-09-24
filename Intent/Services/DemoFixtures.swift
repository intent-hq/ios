import Foundation
import UIKit

/// Launch-argument-driven demo mode for screenshot UI tests: with
/// `--demo-data` the app skips pairing, serves fixture data from
/// `DemoFixtures` instead of a live daemon connection, and runs
/// `PersistenceManager.shared` over an ephemeral store (see
/// `PersistenceManager.ephemeral()`). Zero-impact when the arguments are
/// absent.
enum DemoMode {
    /// True when fixture data should be served (`--demo-data`).
    static let isEnabled = demoDataRequested(by: ProcessInfo.processInfo.arguments)

    /// True when the pairing flow should be skipped (`--pretend-paired`,
    /// implied by `--demo-data`).
    static let pretendPaired = pretendPairedRequested(by: ProcessInfo.processInfo.arguments)

    static func demoDataRequested(by arguments: [String]) -> Bool {
        arguments.contains("--demo-data")
    }

    static func pretendPairedRequested(by arguments: [String]) -> Bool {
        arguments.contains("--pretend-paired") || demoDataRequested(by: arguments)
    }
}

/// Static fixture responses for demo mode. Shapes mirror the daemon's
/// JSON-RPC results exactly as the stores parse them (`workspace.list` →
/// `WorkspaceStore.parseWorkspaces`, `note.list` → `Note.parseNote`,
/// `agent.list` → `AgentSession.parseAgent`, ...).
///
/// Subscribe methods intentionally fall through to the empty-dictionary
/// default: a response without a `subscriptionId` makes every store fall
/// back to its legacy fetch path, which is exactly right for static data.
enum DemoFixtures {
    // Numeric values below are intentional status-image fixture geometry and color data.
    // swiftlint:disable no_magic_numbers number_separator
    nonisolated private static let statusImageSize = CGSize(width: 640, height: 360)
    nonisolated private static let statusImageRowCount = 5
    nonisolated private static let statusImageRowStartY: CGFloat = 48
    nonisolated private static let statusImageRowStride: CGFloat = 60
    nonisolated private static let statusImageRowX: CGFloat = 32
    nonisolated private static let statusImageRowWidth: CGFloat = 576
    nonisolated private static let statusImageRowHeight: CGFloat = 44
    nonisolated private static let statusImageRowCornerRadius: CGFloat = 10
    nonisolated private static let statusImageToggleX: CGFloat = 548
    nonisolated private static let statusImageToggleYOffset: CGFloat = 10
    nonisolated private static let statusImageToggleWidth: CGFloat = 44
    nonisolated private static let statusImageToggleHeight: CGFloat = 24
    nonisolated private static let statusImageToggleCornerRadius: CGFloat = 12
    private static let bytesPerKilobyte = 1_024.0
    private static let secondsPerMinute: TimeInterval = 60
    private static let defaultHookListDelaySeconds = 4
    private static let defaultBlockHydrationDelaySeconds = 4
    private static let triggerFilePollMilliseconds = 100
    // swiftlint:enable no_magic_numbers number_separator

    /// Workspace whose `agent.list` returns `longConversationAgents` instead
    /// of the default `agents` (the "Deflake payment integration tests"
    /// workspace, not part of App Store screenshots 02–04).
    static let longConversationWorkspaceId = "demo-ws-flaky-tests"

    /// Agent whose `agent.getConversation` returns `longConversationMessages`
    /// ("Test Stabilizer", idle). Every other agent keeps the 4-message
    /// `conversationMessages` used by App Store screenshot 03.
    static let longConversationAgentId = "demo-agent-deflake"

    /// Sub-agents delegated by `longConversationAgentId`, in the order they
    /// appear in the transcript's agent-to-agent rows. `agent.getSubscriptions`
    /// for the coordinator reports one delegation group over all three with
    /// the first already complete, so the conversation opens with the
    /// "Waiting for all (1/3)" footer already under the transcript.
    static let longConversationDelegateIds = [
        "demo-agent-deflake-capture",
        "demo-agent-deflake-refund",
        "demo-agent-deflake-webhooks"
    ]

    static let longConversationDelegateNames = [
        "Capture Race Fixer",
        "Refund Settlement Fixer",
        "Webhook Regression Check"
    ]

    /// Name of the single scheduled hook `hook.list` serves for
    /// `longConversationAgentId`. Rendered as a chip in the hooks row above
    /// the composer; the row's own label is "Running hooks".
    static let longConversationHookName = "Wait for CI on flake fix"

    /// The one workspace whose `workspace.list` row carries a
    /// `statusImageAssetId` (the "Dark mode for settings screens" workspace:
    /// no agents, so its row opens the detail header rather than a
    /// conversation), and the asset id `note.readAsset` answers with
    /// `statusImagePNG` (intent-hq/intent#3868).
    static let statusImageWorkspaceId = "demo-ws-dark-mode"
    static let statusImageAssetId = "m9demo00-5e771n65.png"

    /// Rendered once per process: a mock "settings in dark mode" screenshot
    /// (16:9) so the fixture needs no bundled image file.
    static let statusImagePNG: Data = {
        let renderer = UIGraphicsImageRenderer(size: statusImageSize)
        return renderer.pngData(actions: drawStatusImage)
    }()

    nonisolated private static func drawStatusImage(in context: UIGraphicsImageRendererContext) {
        // swiftlint:disable no_magic_numbers
        let background = UIColor(
            cgColor: CGColor(srgbRed: 0.11, green: 0.11, blue: 0.13, alpha: 1)
        )
        let rowFill = UIColor(
            cgColor: CGColor(srgbRed: 0.18, green: 0.18, blue: 0.21, alpha: 1)
        )
        let accent = UIColor(
            cgColor: CGColor(srgbRed: 0.29, green: 0.56, blue: 0.99, alpha: 1)
        )
        // swiftlint:enable no_magic_numbers
        background.setFill()
        context.fill(CGRect(origin: .zero, size: statusImageSize))
        for row in 0..<statusImageRowCount {
            let rowY = statusImageRowStartY + CGFloat(row) * statusImageRowStride
            rowFill.setFill()
            UIBezierPath(
                roundedRect: CGRect(
                    x: statusImageRowX,
                    y: rowY,
                    width: statusImageRowWidth,
                    height: statusImageRowHeight
                ),
                cornerRadius: statusImageRowCornerRadius
            ).fill()
            (row.isMultiple(of: 2) ? accent : rowFill).setFill()
            UIBezierPath(
                roundedRect: CGRect(
                    x: statusImageToggleX,
                    y: rowY + statusImageToggleYOffset,
                    width: statusImageToggleWidth,
                    height: statusImageToggleHeight
                ),
                cornerRadius: statusImageToggleCornerRadius
            ).fill()
        }
    }

    /// What `hook.list` for `longConversationWorkspaceId` waits on before
    /// answering, so the hooks row appears under an already-settled
    /// transcript — the container-resize path of #272 under `--demo-data`
    /// (`ConversationTranscriptScrollUITests`). Every other fixture answers
    /// immediately, apart from `agent.getMessageBlock` behind
    /// `longConversationBlockHydrationGate`. The default delay suits the
    /// screenshot flows; a UI test
    /// that must observe the transcript before the row lands passes
    /// `--demo-hook-list-trigger-file=<path>` and creates that file when it
    /// is ready — a clock cannot be made robust against the render time of a
    /// loaded CI simulator.
    static let longConversationHookListGate = hookListGate(from: ProcessInfo.processInfo.arguments)

    static let defaultHookListDelay: Duration = .seconds(defaultHookListDelaySeconds)

    static let hookListDelayArgumentPrefix = "--demo-hook-list-delay-ms="

    static let hookListTriggerFileArgumentPrefix = "--demo-hook-list-trigger-file="

    /// What `agent.getMessageBlock` for `longConversationAgentId` waits on
    /// before answering: the slow-network hydration of the slim-truncated
    /// tool rows near the end of the long transcript (#338). Same shape as
    /// the hooks-row gate: a delay by default, or a trigger file for a UI
    /// test that releases the hydration itself.
    static let longConversationBlockHydrationGate = blockHydrationGate(from: ProcessInfo.processInfo.arguments)

    static let defaultBlockHydrationDelay: Duration = .seconds(defaultBlockHydrationDelaySeconds)

    static let blockHydrationDelayArgumentPrefix = "--demo-block-hydration-delay-ms="

    static let blockHydrationTriggerFileArgumentPrefix = "--demo-block-hydration-trigger-file="

    /// Polling cadence for `ResponseGate.triggerFile`.
    static let triggerFilePollInterval: Duration = .milliseconds(triggerFilePollMilliseconds)

    /// Condition a fixture response waits on before it is served.
    enum ResponseGate: Equatable {
        case delay(Duration)
        /// Served once the file exists; waits indefinitely otherwise.
        case triggerFile(URL)
    }

    /// `.triggerFile` when the arguments carry a non-empty
    /// `--demo-hook-list-trigger-file=<path>` (the last one wins);
    /// otherwise `.delay` of `hookListDelay(from:)`.
    static func hookListGate(from arguments: [String]) -> ResponseGate {
        gate(
            from: arguments,
            triggerFilePrefix: hookListTriggerFileArgumentPrefix,
            delayPrefix: hookListDelayArgumentPrefix,
            defaultDelay: defaultHookListDelay
        )
    }

    /// `defaultHookListDelay` unless the arguments carry a well-formed
    /// `--demo-hook-list-delay-ms=<milliseconds>`; the last one wins.
    static func hookListDelay(from arguments: [String]) -> Duration {
        delay(from: arguments, prefix: hookListDelayArgumentPrefix, defaultDelay: defaultHookListDelay)
    }

    static func blockHydrationGate(from arguments: [String]) -> ResponseGate {
        gate(
            from: arguments,
            triggerFilePrefix: blockHydrationTriggerFileArgumentPrefix,
            delayPrefix: blockHydrationDelayArgumentPrefix,
            defaultDelay: defaultBlockHydrationDelay
        )
    }

    static func blockHydrationDelay(from arguments: [String]) -> Duration {
        delay(
            from: arguments,
            prefix: blockHydrationDelayArgumentPrefix,
            defaultDelay: defaultBlockHydrationDelay
        )
    }

    private static func gate(
        from arguments: [String],
        triggerFilePrefix: String,
        delayPrefix: String,
        defaultDelay: Duration
    ) -> ResponseGate {
        if let url = triggerFile(from: arguments, prefix: triggerFilePrefix) { return .triggerFile(url) }
        return .delay(delay(from: arguments, prefix: delayPrefix, defaultDelay: defaultDelay))
    }

    private static func triggerFile(from arguments: [String], prefix: String) -> URL? {
        arguments
            .filter { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)) }
            .last { !$0.isEmpty }
            .map { URL(fileURLWithPath: $0) }
    }

    // MARK: - Controlled end derealization (intent-hq/ios#338)

    /// Trigger file that, once created, withdraws the transcript's end row
    /// (the `scroll-bottom` marker) from the lazy stack so the row's real
    /// `onDisappear` arms the unrealized-end recovery at a moment the UI
    /// test chooses (`ConversationTranscriptView`), instead of waiting for
    /// the organic hooks-row re-measure. Nil — nothing changes — without
    /// `--demo-end-derealization-trigger-file=<path>`; the last non-empty
    /// one wins. Trigger-file gated like the fixture gates above, since a
    /// clock cannot be made robust against a loaded CI simulator.
    static let configuredEndDerealizationTriggerFile = endDerealizationTriggerFile(
        from: ProcessInfo.processInfo.arguments
    )

    /// `--demo-end-derealization-mode=<release|hold>`, `release` by default.
    static let configuredEndDerealizationMode = endDerealizationMode(from: ProcessInfo.processInfo.arguments)

    static let endDerealizationTriggerArgumentPrefix = "--demo-end-derealization-trigger-file="

    static let endDerealizationModeArgumentPrefix = "--demo-end-derealization-mode="

    /// What the withdrawn end row waits on before it is put back.
    enum EndDerealizationMode: String, Equatable {
        /// Kept withdrawn so the recovery spends its whole budget and the
        /// give-up path (Go to End) runs.
        case hold
        /// Restored once the live scroll view is measurably paged up — the
        /// recovery's correction — so its follow back re-verifies through
        /// the row's real `onAppear` and the episode resolves.
        case release
    }

    static func endDerealizationTriggerFile(from arguments: [String]) -> URL? {
        triggerFile(from: arguments, prefix: endDerealizationTriggerArgumentPrefix)
    }

    /// `.release` unless the arguments carry a well-formed
    /// `--demo-end-derealization-mode=<release|hold>`; the last one wins.
    static func endDerealizationMode(from arguments: [String]) -> EndDerealizationMode {
        let prefix = endDerealizationModeArgumentPrefix
        return arguments
            .filter { $0.hasPrefix(prefix) }
            .compactMap { EndDerealizationMode(rawValue: String($0.dropFirst(prefix.count))) }
            .last ?? .release
    }

    /// Whether the withdrawn end row is put back for a live scroll view now
    /// resting at `contentOffsetY`, withdrawn at `withdrawnOffsetY`. The
    /// restore is evidence-driven, never timed and never issued by the
    /// recovery itself: in `.release` the viewport must have moved up by at
    /// least half a container — the recovery's page up, not a re-measure
    /// jitter — and in either mode a user gesture that moves the viewport
    /// takes the row back, since the recovery yields to it. Otherwise the
    /// row stays withdrawn.
    static func shouldRestoreDerealizedEnd(
        mode: EndDerealizationMode,
        withdrawnOffsetY: CGFloat,
        contentOffsetY: CGFloat,
        containerHeight: CGFloat,
        isInteracting: Bool
    ) -> Bool {
        let movedUpBy = withdrawnOffsetY - contentOffsetY
        if isInteracting { return abs(movedUpBy) >= 1 }
        switch mode {
        case .release: return movedUpBy >= containerHeight / 2
        case .hold: return false
        }
    }

    private static func delay(from arguments: [String], prefix: String, defaultDelay: Duration) -> Duration {
        let milliseconds = arguments
            .filter { $0.hasPrefix(prefix) }
            .compactMap { Int($0.dropFirst(prefix.count)) }
            .last { $0 >= 0 }
        guard let milliseconds else { return defaultDelay }
        return .milliseconds(milliseconds)
    }

    /// Gate to wait on before serving `response(for:params:)`, or nil for an
    /// immediate answer.
    static func responseGate(for method: String, params: [String: Any]) -> ResponseGate? {
        switch method {
        case "hook.list" where params["workspaceId"] as? String == longConversationWorkspaceId:
            return longConversationHookListGate
        case "agent.getMessageBlock" where params["agentId"] as? String == longConversationAgentId:
            return longConversationBlockHydrationGate
        default:
            return nil
        }
    }

    /// Suspends until `gate` opens; cancellation propagates from `Task.sleep`.
    static func wait(for gate: ResponseGate) async throws {
        switch gate {
        case .delay(let duration):
            try await Task.sleep(for: duration)
        case .triggerFile(let url):
            while !FileManager.default.fileExists(atPath: url.path) {
                try await Task.sleep(for: triggerFilePollInterval)
            }
        }
    }

    /// Fixture response for a JSON-RPC method. Unknown methods return an
    /// empty dictionary, which every call site parses as "no data" safely.
    static func response(for method: String, params: [String: Any]) -> Any {
        switch method {
        case "workspace.list":
            return ["workspaces": workspaces]
        case "note.list":
            return ["notes": notes]
        case "note.get":
            let noteId = params["noteId"] as? String
            let note = notes.first { ($0["id"] as? String) == noteId } ?? notes[0]
            return ["note": note]
        case "note.readAsset":
            return assetResponse(params: params)
        default:
            return agentAndTaskResponse(for: method, params: params)
        }
    }

    private static func assetResponse(params: [String: Any]) -> [String: Any] {
        guard params["workspaceId"] as? String == statusImageWorkspaceId,
              params["asset"] as? String == statusImageAssetId else { return [:] }
        let base64 = statusImagePNG.base64EncodedString()
        return [
            "assetId": statusImageAssetId,
            "mimeType": "image/png",
            "data": base64,
            "sizeKb": Int((Double(base64.utf8.count) / bytesPerKilobyte).rounded())
        ]
    }

    // The fixture switch deliberately mirrors the demo protocol surface.
    // swiftlint:disable:next cyclomatic_complexity
    private static func agentAndTaskResponse(for method: String, params: [String: Any]) -> Any {
        switch method {
        case "agent.list":
            let workspaceId = params["workspaceId"] as? String
            if workspaceId == Workspace.chiefWorkspaceId { return ["agents": assistantAgents] }
            return ["agents": workspaceId == longConversationWorkspaceId ? longConversationAgents : agents]
        case "agent.get":
            let agentId = params["agentId"] as? String
            if agentId == assistantAgentId { return ["agent": assistantAgents[0]] }
            let agent = (agents + longConversationAgents).first { ($0["id"] as? String) == agentId } ?? agents[0]
            return ["agent": agent]
        case "agent.getConversation":
            let agentId = params["agentId"] as? String
            if agentId == assistantAgentId {
                return ["messages": assistantMessages, "truncated": false, "totalMessages": assistantMessages.count]
            }
            let messages = agentId == longConversationAgentId ? longConversationMessages : conversationMessages
            return [
                "messages": messages,
                "truncated": false,
                "totalMessages": messages.count
            ] as [String: Any]
        case "agent.getMessageBlock":
            let blockId = params["blockId"] as? String
            guard let block = longConversationFullBlock(id: blockId) else { return [String: Any]() }
            return ["block": block]
        case "agent.getQueue":
            return ["queue": [[String: Any]]()]
        case "agent.getSubscriptions":
            let agentId = params["agentId"] as? String
            return agentId == longConversationAgentId ? longConversationSubscriptions : [String: Any]()
        case "hook.list":
            let workspaceId = params["workspaceId"] as? String
            return ["hooks": workspaceId == longConversationWorkspaceId ? longConversationHooks : []]
        case "task.list":
            return ["tasks": tasks]
        case "specialist.list":
            return ["specialists": specialists]
        default:
            return [String: Any]()
        }
    }

    /// ISO 8601 timestamp relative to now, so relative-time labels
    /// ("12m ago") always look fresh in screenshots.
    static func iso(minutesAgo: Double) -> String {
        ISO8601DateFormatter().string(
            from: Date(timeIntervalSinceNow: -minutesAgo * secondsPerMinute)
        )
    }
}
