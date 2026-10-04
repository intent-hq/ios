import Foundation
import UIKit

/// Static fixture responses for demo mode. Shapes mirror the daemon's
/// JSON-RPC results exactly as the stores parse them (`workspace.list` →
/// `WorkspaceStore.parseWorkspaces`, `note.list` → `Note.parseNote`,
/// `agent.list` → `AgentSession.parseAgent`, ...).
///
/// Chat subscriptions deliver a snapshot; event feeds acknowledge registrations.
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
    @TaskLocal static var transcriptTimestampAnchor = Date()
    @TaskLocal private static var snapshotTimestampAnchor: Date?
    private static let defaultHookListDelaySeconds = 4
    private static let defaultBlockHydrationDelaySeconds = 4
    private static let triggerFilePollMilliseconds = 100
    // swiftlint:enable no_magic_numbers number_separator

    /// Workspace whose `agent.list` returns `longConversationAgents` instead
    /// of the default `agents` (the "Deflake payment integration tests"
    /// workspace, not part of App Store screenshots 02–04).
    static let longConversationWorkspaceId = "demo-ws-flaky-tests"

    /// Agent whose `chat.subscribe` snapshot (and `agent.getConversation`
    /// seek) serves `longConversationMessages` ("Test Stabilizer", idle).
    /// Every other agent keeps the 4-message `conversationMessages` used by
    /// App Store screenshot 03.
    static let longConversationAgentId = "demo-agent-deflake"

    /// `subscriptionId` a demo `chat.subscribe` acks with; the seq-0 snapshot
    /// it owes is routed through `subscriptionPush(for:params:)`.
    static func chatSubscriptionId(agentId: String?) -> String {
        "demo-chat-\(agentId ?? "unknown")"
    }

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

    /// Delays the long transcript's hooks row for container-resize tests (#272).
    /// UI tests release a trigger file after observing the transcript; a fixed
    /// delay cannot account for a loaded simulator. Screenshot flows use the
    /// default delay. Metadata/snapshot and hydration gates are independent.
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
        if let gate = agentGroupResponseGate(for: method, params: params, arguments: ProcessInfo.processInfo.arguments) { return gate }
        if let gate = startupResponseGate(for: method, params: params, arguments: ProcessInfo.processInfo.arguments) { return gate }
        switch method {
        case "workspace.create":
            return triggerFile(from: ProcessInfo.processInfo.arguments, prefix: "--demo-workspace-create-trigger-file=").map(ResponseGate.triggerFile)
        case "github.authStatus", "github.branches.list", "github.branches.listCached":
            return triggerFile(from: ProcessInfo.processInfo.arguments, prefix: "--demo-workspace-selection-trigger-file=").map(ResponseGate.triggerFile)
        case "settings.get" where params["path"] as? String == "providers.enabled":
            return workspaceProviderGate(from: ProcessInfo.processInfo.arguments)
        case "workspace.list":
            return DemoConnectionLoss.initialDataGate
        case "hook.list" where params["workspaceId"] as? String == longConversationWorkspaceId:
            return longConversationHookListGate
        case "agent.getMessageBlock" where params["agentId"] as? String == longConversationAgentId:
            return longConversationBlockHydrationGate
        default:
            return nil
        }
    }

    /// The loading UI test releases this response only after observing it.
    static func agentGroupResponseGate(for method: String, params: [String: Any], arguments: [String]) -> ResponseGate? {
        guard method == "agent.list", params["scope"] as? String == "background",
              DemoDesignScenario.requested(by: arguments) == .agentGroupsRetry else { return nil }
        return triggerFile(from: arguments, prefix: "--demo-agent-group-trigger-file=").map(ResponseGate.triggerFile)
    }

    /// Holds workspace policy validation until the UI test releases it (#446).
    /// Without the argument, ordinary demo requests still answer immediately.
    static func workspaceProviderGate(from arguments: [String]) -> ResponseGate? {
        triggerFile(from: arguments, prefix: "--demo-workspace-provider-trigger-file=").map(ResponseGate.triggerFile)
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
}

extension DemoFixtures {
    /// Chat snapshots, plus opt-in design scenario updates after commands.
    static func subscriptionPush(for method: String, params: [String: Any]) -> SubscriptionPush? {
        if let push = designScenario?.subscriptionPush(for: method, params: params) { return push }
        guard method == "chat.subscribe" else { return nil }
        let agentId = params["agentId"] as? String
        let messages = transcriptMessages(agentId: agentId)
        return SubscriptionPush(
            subscriptionId: chatSubscriptionId(agentId: agentId),
            seq: 0,
            conversationSnapshot: messages,
            metadata: ["truncated": false, "totalMessages": messages.count]
        )
    }

    static func transcriptMessages(agentId: String?) -> [[String: Any]] {
        if agentId == "demo-agent-implementor", let messages = DemoBrowserFixtures.conversationMessages { return messages }
        if usesStartupTranscript, agentId == longConversationAgentId { return startupTranscriptMessages }
        if let designScenario, agentId == DemoDesignFixtures.agentId { return designScenario.messages }
        if inlineImageConversationRequested(by: ProcessInfo.processInfo.arguments),
           agentId == inlineImageAgentId {
            return inlineImageConversationMessages
        }
        if agentId == assistantAgentId { return assistantMessages }
        if assistantAgents.contains(where: { ($0["id"] as? String) == agentId }) { return [] }
        return agentId == longConversationAgentId ? longConversationMessages : conversationMessages
    }

    /// JSON-RPC fixture response. Unknown methods return an empty dictionary.
    static func response(
        for method: String,
        params: [String: Any],
        snapshotAnchor: Date = Date()
    ) -> Any {
        if let response = DemoWorkspaceActionFixtures.response(for: method, params: params) { return response }
        if let response = designScenario?.response(for: method, params: params)
            ?? DemoTerminalFixtures.response(for: method, params: params)
            ?? DemoBrowserFixtures.response(for: method, params: params) { return response }
        if let changesResponse = DemoChangesFixtures.response(for: method, params: params) { return changesResponse }
        return $snapshotTimestampAnchor.withValue(snapshotAnchor) {
            workspaceAndNoteResponse(for: method, params: params)
        }
    }

    private static func workspaceAndNoteResponse(for method: String, params: [String: Any]) -> Any {
        if let response = proposalResponse(for: method, params: params) { return response }
        switch method {
        case "events.subscribe": return ["subscriptionId": "demo-events-\(params["replaceGroup"] as? String ?? "default")"]
        case "prMonitor.list": return ["monitors": [[String: Any]]()]
        case "workspace.list": return ["workspaces": workspaces]
        case "workspace.transfer.plan":
            return [
                "plan": [
                    "manifest": [
                        "workspaceId": params["workspaceId"] ?? "demo-workspace",
                        "creatingIntentdVersion": "demo"
                    ],
                    "totalSizeBytes": 0,
                    "warnings": [[String: String]]()
                ]
            ]
        case "note.list": return ["notes": notes]
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
        case "agent.create" where params["workspaceId"] as? String == Workspace.chiefWorkspaceId:
            return createAssistantAgent()
        case "agent.list":
            let workspaceId = params["workspaceId"] as? String
            if workspaceId == Workspace.chiefWorkspaceId { return ["agents": assistantAgents] }
            return DemoAgentListFixtures.response(rows: workspaceId == longConversationWorkspaceId ? longConversationAgents : agents, params: params)
        case "agent.get":
            let agentId = params["agentId"] as? String
            if let assistant = assistantAgents.first(where: { ($0["id"] as? String) == agentId }) {
                return ["agent": assistant]
            }
            var agent = (agents + longConversationAgents).first { ($0["id"] as? String) == agentId } ?? agents[0]
            if usesStartupTranscript, agentId == longConversationAgentId {
                agent["metadata"] = ["lastSeenMessageId": startupSeenMessageId]
            }
            return ["agent": agent]
        case "agent.getConversation":
            let messages = transcriptMessages(agentId: params["agentId"] as? String)
            return [
                "messages": messages,
                "truncated": false,
                "totalMessages": messages.count
            ] as [String: Any]
        case "chat.subscribe":
            return ["subscriptionId": chatSubscriptionId(agentId: params["agentId"] as? String)]
        case "agent.getMessageBlock":
            let blockId = params["blockId"] as? String
            guard let block = longConversationFullBlock(id: blockId) else { return [String: Any]() }
            return ["block": block]
        case "agent.sendMessage":
            // Static transcripts have no replying agent; acknowledge the send
            // without replacing its optimistic row or ending the Thinking state.
            var response: [String: Any] = ["success": true, "queued": false]
            response["messageId"] = params["messageId"] as? String
            return response
        case "agent.getQueue":
            return ["queue": [[String: Any]]()]
        case "agent.getSubscriptions":
            let agentId = params["agentId"] as? String
            if usesStartupTranscript, agentId == longConversationAgentId { return ["subscriptions": []] }
            return agentId == longConversationAgentId ? longConversationSubscriptions : [String: Any]()
        case "hook.list":
            let workspaceId = params["workspaceId"] as? String
            return ["hooks": workspaceId == longConversationWorkspaceId ? longConversationHooks : []]
        case "task.list":
            return ["tasks": tasks]
        case "specialist.list":
            return ["specialists": specialists]
        default:
            return workspaceCreationResponse(for: method, params: params)
        }
    }
}

extension DemoFixtures {
    /// Non-transcript timestamp relative to one response's snapshot time, so
    /// relative-time labels and future events refresh together on each request.
    static func iso(minutesAgo: Double) -> String {
        iso(minutesAgo: minutesAgo, relativeTo: snapshotTimestampAnchor ?? Date())
    }

    /// Transcript timestamp relative to the process-stable message anchor, so
    /// independently rebuilt snapshots preserve immutable message identity.
    static func transcriptIso(minutesAgo: Double) -> String {
        iso(minutesAgo: minutesAgo, relativeTo: transcriptTimestampAnchor)
    }

    static func iso(minutesAgo: Double, relativeTo anchor: Date) -> String {
        ISO8601DateFormatter().string(
            from: anchor.addingTimeInterval(-minutesAgo * secondsPerMinute)
        )
    }
}
