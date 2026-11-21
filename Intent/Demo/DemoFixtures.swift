#if DEBUG
import Foundation
import UIKit

enum DemoFixtures {
    // swiftlint:disable no_magic_numbers
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
    private static let bytesPerKilobyte = 1024.0
    static let secondsPerMinute: TimeInterval = 60
    @TaskLocal static var transcriptTimestampAnchor = Date()
    @TaskLocal static var snapshotTimestampAnchor: Date?
    private static let defaultHookListDelaySeconds = 4
    private static let defaultBlockHydrationDelaySeconds = 4
    private static let triggerFilePollMilliseconds = 100
    // swiftlint:enable no_magic_numbers
    static let longConversationWorkspaceId = "demo-ws-flaky-tests"

    static let longConversationAgentId = "demo-agent-deflake"

    static func chatSubscriptionId(agentId: String?) -> String {
        "demo-chat-\(agentId ?? "unknown")"
    }

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

    static let longConversationHookName = "Wait for CI on flake fix"

    static let statusImageWorkspaceId = "demo-ws-dark-mode"
    static let statusImageAssetId = "m9demo00-5e771n65.png"

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

    static let longConversationHookListGate = hookListGate(from: LaunchOptions.current.arguments)

    static let defaultHookListDelay: Duration = .seconds(defaultHookListDelaySeconds)

    static let hookListDelayArgumentPrefix = "--demo-hook-list-delay-ms="

    static let hookListTriggerFileArgumentPrefix = "--demo-hook-list-trigger-file="

    static let longConversationBlockHydrationGate = blockHydrationGate(from: LaunchOptions.current.arguments)

    static let defaultBlockHydrationDelay: Duration = .seconds(defaultBlockHydrationDelaySeconds)

    static let blockHydrationDelayArgumentPrefix = "--demo-block-hydration-delay-ms="

    static let blockHydrationTriggerFileArgumentPrefix = "--demo-block-hydration-trigger-file="

    static let triggerFilePollInterval: Duration = .milliseconds(triggerFilePollMilliseconds)

    enum ResponseGate: Equatable {
        case delay(Duration)
        case triggerFile(URL)
    }

    static func hookListGate(from arguments: [String]) -> ResponseGate {
        gate(
            from: arguments,
            triggerFilePrefix: hookListTriggerFileArgumentPrefix,
            delayPrefix: hookListDelayArgumentPrefix,
            defaultDelay: defaultHookListDelay
        )
    }

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

    static func triggerFile(from arguments: [String], prefix: String) -> URL? {
        arguments
            .filter { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)) }
            .last { !$0.isEmpty }
            .map { URL(fileURLWithPath: $0) }
    }

    // MARK: - Controlled end derealization (intent-hq/ios#338)

    static let configuredEndDerealizationTriggerFile = endDerealizationTriggerFile(
        from: LaunchOptions.current.arguments
    )

    static let configuredEndDerealizationMode = endDerealizationMode(from: LaunchOptions.current.arguments)

    static let endDerealizationTriggerArgumentPrefix = "--demo-end-derealization-trigger-file="

    static let endDerealizationModeArgumentPrefix = "--demo-end-derealization-mode="
    private static let deepReleaseViewports: CGFloat = 2.5

    enum EndDerealizationMode: String, Equatable {
        case deepRelease = "deep-release"
        case hold
        case release
    }

    static func endDerealizationTriggerFile(from arguments: [String]) -> URL? {
        triggerFile(from: arguments, prefix: endDerealizationTriggerArgumentPrefix)
    }

    static func endDerealizationMode(from arguments: [String]) -> EndDerealizationMode {
        let prefix = endDerealizationModeArgumentPrefix
        return arguments
            .filter { $0.hasPrefix(prefix) }
            .compactMap { EndDerealizationMode(rawValue: String($0.dropFirst(prefix.count))) }
            .last ?? .release
    }

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
        case .deepRelease: return movedUpBy >= containerHeight * deepReleaseViewports
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

    private static let responseTriggerFilePrefixes = [
        "workspace.create": "--demo-workspace-create-trigger-file=",
        "github.authStatus": "--demo-workspace-selection-trigger-file=",
        "github.branches.list": "--demo-workspace-selection-trigger-file=",
        "github.branches.listCached": "--demo-workspace-selection-trigger-file="
    ]

    static func responseGate(for method: String, params: [String: Any]) -> ResponseGate? {
        if let gate = historyResponseGate(for: method, params: params) { return gate }
        if let gate = DemoConnectionLoss.conversationLoadGate(for: method) { return gate }
        if let gate = agentGroupResponseGate(for: method, params: params, arguments: LaunchOptions.current.arguments) { return gate }
        if let gate = startupResponseGate(for: method, params: params, arguments: LaunchOptions.current.arguments) { return gate }
        if let prefix = responseTriggerFilePrefixes[method] {
            return triggerFile(from: LaunchOptions.current.arguments, prefix: prefix).map(ResponseGate.triggerFile)
        }
        switch method {
        case "settings.get" where params["path"] as? String == "providers.enabled": return workspaceProviderGate(from: LaunchOptions.current.arguments)
        case "workspace.list": return DemoConnectionLoss.initialDataGate
        case "hook.list" where params["workspaceId"] as? String == longConversationWorkspaceId: return longConversationHookListGate
        case "agent.getMessageBlock" where params["agentId"] as? String == longConversationAgentId: return longConversationBlockHydrationGate
        default: return assistantListGate(for: method, params: params)
        }
    }

    static func agentGroupResponseGate(for method: String, params: [String: Any], arguments: [String]) -> ResponseGate? {
        guard method == "agent.list", params["scope"] as? String == "background",
              DemoDesignScenario.requested(by: arguments) == .agentGroupsRetry else { return nil }
        return triggerFile(from: arguments, prefix: "--demo-agent-group-trigger-file=").map(ResponseGate.triggerFile)
    }

    static func workspaceProviderGate(from arguments: [String]) -> ResponseGate? {
        triggerFile(from: arguments, prefix: "--demo-workspace-provider-trigger-file=").map(ResponseGate.triggerFile)
    }

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
    static func subscriptionPush(for method: String, params: [String: Any]) -> SubscriptionPush? {
        #if DEBUG
        if startupSnapshotIsHeld(for: method, params: params, arguments: LaunchOptions.current.arguments) { return nil }
        #endif
        if let push = designScenario?.subscriptionPush(for: method, params: params) { return push }
        guard method == "chat.subscribe" else { return nil }
        let agentId = params["agentId"] as? String
        if let push = historySubscriptionPush(params: params) { return push }
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
        if usesTranscriptVideo, agentId == "demo-agent-implementor" { return transcriptVideoMessages }
        if usesInlinePDF, agentId == "demo-agent-implementor" { return inlinePDFMessages }
        if usesInlineText, agentId == "demo-agent-implementor" { return inlineTextMessages }
        if inlineImageConversationRequested(by: LaunchOptions.current.arguments),
           agentId == inlineImageAgentId { return inlineImageConversationMessages }
        if agentId == assistantAgentId { return assistantMessages }
        if assistantAgents.contains(where: { ($0["id"] as? String) == agentId }) { return [] }
        return agentId == longConversationAgentId ? longConversationMessages : conversationMessages
    }

    static func response(for method: String, params: [String: Any], snapshotAnchor: Date = Date()) -> Any {
        if let response = assistantModelResponse(for: method, params: params) { return response }
        if let response = transcriptVideoResponse(for: method, params: params) { return response }
        if let response = inlinePDFResponse(for: method, params: params) { return response }
        if let response = inlineTextResponse(for: method, params: params) { return response }
        if let response = DemoWorkspaceActionFixtures.response(for: method, params: params) { return response }
        if let response = designScenario?.response(for: method, params: params)
            ?? DemoTerminalFixtures.response(for: method, params: params)
            ?? DemoBrowserFixtures.response(for: method, params: params) { return response }
        if let changesResponse = DemoChangesFixtures.response(for: method, params: params) { return changesResponse }
        if let response = DemoFilesFixtures.response(for: method, params: params) ?? DemoPullRequestFixtures.response(for: method, params: params) { return response }
        if let response = DemoSharingFixtures.response(for: method, params: params) { return response }
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

    private static let agentAndTaskResponses: [String: @MainActor ([String: Any]) -> Any] = [
        "agent.create": { $0["workspaceId"] as? String == Workspace.chiefWorkspaceId ? createAssistantAgent() : workspaceCreationResponse(for: "agent.create", params: $0) },
        "agent.list": agentListResponse,
        "agent.delete": deleteAssistantAgent,
        "agent.get": agentGetResponse,
        "agent.getConversation": conversationResponse,
        "chat.subscribe": { ["subscriptionId": chatSubscriptionId(agentId: $0["agentId"] as? String)] },
        "agent.getMessageBlock": { params in
            guard let block = longConversationFullBlock(id: params["blockId"] as? String) else { return [String: Any]() }
            return ["block": block]
        },
        "agent.sendMessage": sendMessageResponse,
        "agent.getQueue": { _ in ["queue": [[String: Any]]()] },
        "agent.getSubscriptions": subscriptionsResponse,
        "hook.list": { ["hooks": $0["workspaceId"] as? String == longConversationWorkspaceId ? longConversationHooks : []] },
        "task.list": { _ in ["tasks": tasks] },
        "specialist.list": { _ in ["specialists": specialists] }
    ]

    private static func agentAndTaskResponse(for method: String, params: [String: Any]) -> Any {
        agentAndTaskResponses[method]?(params) ?? workspaceCreationResponse(for: method, params: params)
    }

    private static func agentListResponse(params: [String: Any]) -> Any {
        let workspaceId = params["workspaceId"] as? String
        if workspaceId == Workspace.chiefWorkspaceId { return assistantListResponse() }
        return DemoAgentListFixtures.response(rows: workspaceId == longConversationWorkspaceId ? longConversationAgents : agents, params: params)
    }

    private static func agentGetResponse(params: [String: Any]) -> Any {
        let agentId = params["agentId"] as? String
        if let assistant = assistantAgents.first(where: { ($0["id"] as? String) == agentId }) { return ["agent": assistantDetail(assistant)] }
        var agent = (agents + longConversationAgents).first { ($0["id"] as? String) == agentId } ?? agents[0]
        if usesStartupTranscript, agentId == longConversationAgentId {
            agent["metadata"] = ["lastSeenMessageId": startupSeenMessageId]
        }
        return ["agent": agent]
    }

    private static func sendMessageResponse(params: [String: Any]) -> Any {
        var response: [String: Any] = ["success": true, "queued": false]
        response["messageId"] = params["messageId"] as? String
        return response
    }

    private static func subscriptionsResponse(params: [String: Any]) -> Any {
        let agentId = params["agentId"] as? String
        if usesStartupTranscript, agentId == longConversationAgentId { return ["subscriptions": []] }
        return agentId == longConversationAgentId ? longConversationSubscriptions : [String: Any]()
    }
}
#endif
