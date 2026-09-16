import Foundation
import Testing
import UIKit
@testable import Intent

@MainActor
struct DemoFixturesTests {

    // MARK: - Launch-argument gating

    @Test func demoModeInactiveWithoutArguments() {
        #expect(!DemoMode.demoDataRequested(by: []))
        #expect(!DemoMode.demoDataRequested(by: ["/path/to/Intent"]))
        #expect(!DemoMode.pretendPairedRequested(by: ["/path/to/Intent"]))
    }

    @Test func demoModeIgnoresSimilarArguments() {
        #expect(!DemoMode.demoDataRequested(by: ["--demo-data-extra", "demo-data", "--demo"]))
        #expect(!DemoMode.pretendPairedRequested(by: ["pretend-paired", "--pretend"]))
    }

    @Test func demoDataArgumentEnablesDemoMode() {
        #expect(DemoMode.demoDataRequested(by: ["/path/to/Intent", "--demo-data"]))
    }

    @Test func demoDataImpliesPretendPaired() {
        #expect(DemoMode.pretendPairedRequested(by: ["--demo-data"]))
    }

    @Test func pretendPairedAloneDoesNotEnableFixtures() {
        #expect(DemoMode.pretendPairedRequested(by: ["--pretend-paired"]))
        #expect(!DemoMode.demoDataRequested(by: ["--pretend-paired"]))
    }

    @Test func normalLaunchLeavesDemoModeOff() {
        // The live values are computed from the real process arguments; the
        // test runner never passes the demo flags, so both must be false.
        #expect(!DemoMode.isEnabled)
        #expect(!DemoMode.pretendPaired)
    }

    // MARK: - Fixture shape: parses through the real store parsers

    @Test func workspaceListFixtureParses() {
        let result = DemoFixtures.response(for: "workspace.list", params: [:])
        let workspaces = WorkspaceStore.parseWorkspaces(from: result)
        #expect(workspaces.count == 5)
        #expect(workspaces.allSatisfy { !$0.title.isEmpty })
        // At least one workspace carries an agent summary for the detail screen
        #expect(workspaces.contains { ($0.agentSummaryAgents?.count ?? 0) > 0 })
    }

    @Test func noteListFixtureParses() throws {
        let result = DemoFixtures.response(for: "note.list", params: [:])
        let dict = try #require(result as? [String: Any])
        let items = try #require(dict["notes"] as? [[String: Any]])
        let notes = items.compactMap { Note.parseNote($0) }
        #expect(notes.count == items.count)
        #expect(notes.contains { $0.isDefault })
        // A task note with checkboxes is present for the note detail screenshot
        #expect(notes.contains { $0.taskStatus != nil && $0.content.contains("- [ ]") })
    }

    @Test func exactlyOneWorkspaceFixtureCarriesAStatusImage() throws {
        // The status-image UI test relies on one — and only one — workspace
        // row rendering the status thumbnail (intent-hq/intent#3868).
        let result = DemoFixtures.response(for: "workspace.list", params: [:])
        let withImage = WorkspaceStore.parseWorkspaces(from: result)
            .filter { $0.statusImageAssetId != nil }
        #expect(withImage.count == 1)
        #expect(withImage.first?.id == DemoFixtures.statusImageWorkspaceId)
        #expect(withImage.first?.statusImageAssetId == DemoFixtures.statusImageAssetId)
    }

    @Test func noteReadAssetFixtureServesADecodableStatusImage() throws {
        let result = DemoFixtures.response(
            for: "note.readAsset",
            params: [
                "workspaceId": DemoFixtures.statusImageWorkspaceId,
                "asset": DemoFixtures.statusImageAssetId,
            ])
        let dict = try #require(result as? [String: Any])
        #expect(dict["assetId"] as? String == DemoFixtures.statusImageAssetId)
        #expect(dict["mimeType"] as? String == "image/png")
        let base64 = try #require(dict["data"] as? String)
        let bytes = try #require(Data(base64Encoded: base64))
        let image = try #require(WorkspaceFileImageLoader.decodeImage(bytes))
        #expect(image.size.width > 0)
        #expect(image.size.height > 0)
    }

    @Test func noteReadAssetFixtureIsEmptyForUnknownAssets() throws {
        let result = DemoFixtures.response(
            for: "note.readAsset", params: ["workspaceId": "demo-ws-dashboard", "asset": "missing.png"])
        let dict = try #require(result as? [String: Any])
        #expect(dict.isEmpty)
    }

    @Test func agentListFixtureParses() throws {
        let result = DemoFixtures.response(for: "agent.list", params: [:])
        let dict = try #require(result as? [String: Any])
        let items = try #require(dict["agents"] as? [[String: Any]])
        let agents = items.compactMap { AgentSession.parseAgent($0) }
        #expect(agents.count == items.count)
        #expect(agents.count >= 2)
    }

    @Test func conversationFixtureParses() throws {
        let result = DemoFixtures.response(for: "agent.getConversation", params: [:])
        let dict = try #require(result as? [String: Any])
        let items = try #require(dict["messages"] as? [[String: Any]])
        let messages = items.compactMap { ConversationMessage.parseMessage($0) }
        #expect(messages.count == items.count)
        #expect(messages.contains { $0.role == .user })
        #expect(messages.contains { $0.role == .assistant })
        // Every message renders at least one text block
        #expect(messages.allSatisfy { message in
            message.contentBlocks?.contains { $0.resolvedText?.isEmpty == false } == true
        })
    }

    // MARK: - Per-agent conversation routing

    private func conversationMessages(agentId: String?) throws -> (items: [[String: Any]], total: Int) {
        var params: [String: Any] = [:]
        if let agentId { params["agentId"] = agentId }
        let result = DemoFixtures.response(for: "agent.getConversation", params: params)
        let dict = try #require(result as? [String: Any])
        let items = try #require(dict["messages"] as? [[String: Any]])
        let total = try #require(dict["totalMessages"] as? Int)
        return (items, total)
    }

    private func text(of message: [String: Any]) -> String {
        let blocks = message["contentBlocks"] as? [[String: Any]] ?? []
        return blocks.compactMap { $0["text"] as? String }.joined()
    }

    @Test func conversationDefaultsToScreenshotTranscript() throws {
        let noAgent = try conversationMessages(agentId: nil)
        let implementor = try conversationMessages(agentId: "demo-agent-implementor")
        let reviewer = try conversationMessages(agentId: "demo-agent-reviewer")
        for conversation in [noAgent, implementor, reviewer] {
            #expect(conversation.items.count == 4)
            #expect(conversation.total == 4)
            #expect(conversation.items.contains { text(of: $0).contains("more than 90 days") })
        }
    }

    @Test func longConversationRoutesByAgentId() throws {
        let long = try conversationMessages(agentId: DemoFixtures.longConversationAgentId)
        #expect(long.items.count >= 150)
        #expect(long.total == long.items.count)

        let messages = long.items.compactMap { ConversationMessage.parseMessage($0) }
        #expect(messages.count == long.items.count)
        #expect(messages.allSatisfy { $0.role == .user || $0.role == .assistant })
        #expect(messages.first?.role == .user)
        #expect(messages.last?.role == .assistant)
        #expect(Set(long.items.compactMap { $0["id"] as? String }).count == long.items.count)
        // Timestamps descend from the first message to the last.
        let timestamps = long.items.compactMap { $0["timestamp"] as? String }
        #expect(timestamps.count == long.items.count)
        #expect(timestamps == timestamps.sorted())

        let first = try #require(long.items.first)
        let last = try #require(long.items.last)
        #expect(text(of: first).hasPrefix(DemoFixtures.longConversationFirstSentence))
        // The last message carries the suggested-prompts block after its
        // closing sentence; the rendered (stripped) text still ends there.
        let lastText = text(of: last)
        #expect(SuggestedPrompts.parse(lastText) == DemoFixtures.longConversationSuggestedPrompts)
        #expect(DemoFixtures.longConversationSuggestedPrompts.count == 3)
        #expect(SuggestedPrompts.stripBlocks(from: lastText)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .hasSuffix(DemoFixtures.longConversationLastSentence))
        #expect(!long.items.contains { text(of: $0).contains("more than 90 days") })
        // The anchors the transcript UI tests match on stay unique.
        #expect(long.items.filter { text(of: $0).contains(DemoFixtures.longConversationFirstSentence) }.count == 1)
        #expect(long.items.filter { text(of: $0).contains(DemoFixtures.longConversationLastSentence) }.count == 1)
    }

    /// The short conversation (intent-hq/ios#346): two messages whose reply
    /// carries a code block of `lineCount` lines between its opening
    /// paragraph and the closing sentence, then the suggested prompts —
    /// under stable ids, so a regrown reply merges into its existing row.
    @Test func shortConversationRoutesByAgentIdAndGrowsByLineCount() throws {
        let short = try conversationMessages(agentId: DemoFixtures.shortConversationAgentId)
        #expect(short.items.count == 2)
        #expect(short.total == 2)
        let messages = short.items.compactMap { ConversationMessage.parseMessage($0) }
        #expect(messages.map(\.role) == [.user, .assistant])
        #expect(!short.items.contains { text(of: $0).contains("more than 90 days") })

        let last = try #require(short.items.last)
        let lastText = text(of: last)
        #expect(SuggestedPrompts.parse(lastText) == DemoFixtures.shortConversationSuggestedPrompts)
        #expect(DemoFixtures.shortConversationSuggestedPrompts.count == 3)
        #expect(SuggestedPrompts.stripBlocks(from: lastText)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .hasSuffix(DemoFixtures.shortConversationLastSentence))
        #expect(short.items.filter { text(of: $0).contains(DemoFixtures.shortConversationLastSentence) }.count == 1)

        func codeLines(lineCount: Int) -> [String] {
            let reply = DemoFixtures.shortConversationMessages(lineCount: lineCount).last.map(text(of:)) ?? ""
            let fenced = reply.components(separatedBy: "```")
            return fenced.count == 3 ? fenced[1].split(separator: "\n").map(String.init) : []
        }
        // No growth file in the test runner: the baseline count is rendered.
        #expect(codeLines(lineCount: DemoFixtures.shortConversationLineCount()).count
            == DemoFixtures.shortConversationBaselineLineCount)
        #expect(codeLines(lineCount: 7).count == 7)
        #expect(codeLines(lineCount: 40).count == 40)
        #expect(codeLines(lineCount: 40).allSatisfy { $0.count < 40 })
        let baselineIds = DemoFixtures.shortConversationMessages(lineCount: 2).map { $0["id"] as? String }
        #expect(DemoFixtures.shortConversationMessages(lineCount: 40).map { $0["id"] as? String } == baselineIds)
    }

    @Test func shortConversationGrowthFileComesFromTheLaunchArgument() {
        #expect(DemoFixtures.shortConversationGrowthFile(from: ["--demo-data"]) == nil)
        #expect(DemoFixtures.shortConversationGrowthFile(from: ["--demo-short-conversation-growth-file="]) == nil)
        #expect(DemoFixtures.shortConversationGrowthFile(from: [
            "--demo-short-conversation-growth-file=/tmp/a.count",
            "--demo-short-conversation-growth-file=/tmp/b.count",
            "--demo-short-conversation-growth-file=",
        ]) == URL(fileURLWithPath: "/tmp/b.count"))
        // The test runner never passes the argument.
        #expect(DemoFixtures.shortConversationGrowthFile == nil)
    }

    @Test func shortConversationLineCountParsesAPositiveIntegerOrFallsBack() {
        let baseline = DemoFixtures.shortConversationBaselineLineCount
        #expect(DemoFixtures.shortConversationLineCount(parsing: nil) == baseline)
        #expect(DemoFixtures.shortConversationLineCount(parsing: "") == baseline)
        #expect(DemoFixtures.shortConversationLineCount(parsing: "0") == baseline)
        #expect(DemoFixtures.shortConversationLineCount(parsing: "-3") == baseline)
        #expect(DemoFixtures.shortConversationLineCount(parsing: "many") == baseline)
        #expect(DemoFixtures.shortConversationLineCount(parsing: "12") == 12)
        #expect(DemoFixtures.shortConversationLineCount(parsing: " 12\n") == 12)
    }

    @Test func shortConversationGrowthNotificationIsATerminalStreamEndForItsAgent() throws {
        let data = try #require(DemoFixtures.shortConversationGrowthNotification.data(using: .utf8))
        let envelope = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(envelope["method"] as? String == "events.event")
        let params = try #require(envelope["params"] as? [String: Any])
        let event = try #require(params["event"] as? [String: Any])
        #expect(event["type"] as? String == "agent:stream:end")
        let payload = try #require(event["data"] as? [String: Any])
        #expect(payload["agentId"] as? String == DemoFixtures.shortConversationAgentId)
        #expect(payload["workspaceId"] as? String == DemoFixtures.shortConversationWorkspaceId)
    }

    /// The long transcript is coordinator-shaped (intent-hq/ios#304, #305):
    /// paired tool calls, agent-to-agent report rows attributed to the
    /// delegates the coordinator waits on, thinking blocks, and markdown
    /// with fenced code — so rows vary widely in height.
    @Test func longConversationMixesToolCallsAgentMessagesAndMarkdown() throws {
        let long = try conversationMessages(agentId: DemoFixtures.longConversationAgentId)
        let messages = long.items.compactMap { ConversationMessage.parseMessage($0) }
        let blocks = messages.flatMap { $0.contentBlocks ?? [] }

        let toolUses = blocks.filter { $0.type == .toolUse }
        let toolResults = blocks.filter { $0.type == .toolResult }
        #expect(toolUses.count >= 30)
        #expect(toolUses.allSatisfy { $0.resolvedName?.isEmpty == false })
        let resultIds = Set(toolResults.compactMap(\.resolvedToolUseId))
        #expect(toolUses.allSatisfy { resultIds.contains($0.id) })
        #expect(Set(toolUses.map(\.id)).count == toolUses.count)
        #expect(blocks.contains { $0.type == .thinking })

        let agentRows = messages.filter { $0.agentMessageAttribution != nil }
        #expect(agentRows.count >= 40)
        #expect(agentRows.allSatisfy { $0.role == .user })
        let senders = Set(agentRows.compactMap { $0.agentMessageAttribution?.fromAgentId })
        #expect(senders == Set(DemoFixtures.longConversationDelegateIds))
        #expect(agentRows.allSatisfy { row in
            let attribution = row.agentMessageAttribution
            return DemoFixtures.longConversationDelegateNames.contains(attribution?.rawName ?? "")
        })

        let texts = blocks.filter { $0.type == .text }.compactMap(\.resolvedText)
        #expect(texts.filter { $0.contains("```") }.count >= 30)
        // Tool-call groups: the open tag and the close tag sit in different
        // text blocks around the tool_use/tool_result pairs.
        #expect(texts.contains { $0.contains("<group:") && !$0.contains("</group>") })
        #expect(texts.contains { $0.contains("</group>") && !$0.contains("<group:") })
        #expect(texts.contains { $0.contains("| Percentile | Duration |") })
        #expect(messages.contains { ($0.contentBlocks?.count ?? 0) >= 5 })
    }

    @Test func subscriptionsReportTheDelegationGroupForTheLongConversationAgent() throws {
        let result = DemoFixtures.response(
            for: "agent.getSubscriptions",
            params: ["agentId": DemoFixtures.longConversationAgentId, "workspaceId": DemoFixtures.longConversationWorkspaceId])
        let dict = try #require(result as? [String: Any])
        let groups = try #require(dict["delegationGroups"] as? [[String: Any]])
        let group = try #require(groups.first)
        #expect(groups.count == 1)
        #expect(group["expectedAgentIds"] as? [String] == DemoFixtures.longConversationDelegateIds)
        #expect((group["completedAgentIds"] as? [String])?.count == 1)
        let subscriptions = try #require(dict["subscriptions"] as? [[String: Any]])
        #expect(subscriptions.allSatisfy { ($0["actorIds"] as? [String]).map { !$0.isEmpty } == true })

        let other = DemoFixtures.response(
            for: "agent.getSubscriptions", params: ["agentId": "demo-agent-implementor"])
        let otherDict = try #require(other as? [String: Any])
        #expect(otherDict.isEmpty)
    }

    @Test func agentListRoutesByWorkspaceId() throws {
        func agentIds(workspaceId: String?) throws -> [String] {
            var params: [String: Any] = [:]
            if let workspaceId { params["workspaceId"] = workspaceId }
            let result = DemoFixtures.response(for: "agent.list", params: params)
            let dict = try #require(result as? [String: Any])
            let items = try #require(dict["agents"] as? [[String: Any]])
            return items.compactMap { AgentSession.parseAgent($0)?.id }
        }
        #expect(try agentIds(workspaceId: nil).contains("demo-agent-implementor"))
        #expect(try agentIds(workspaceId: "demo-ws-dashboard").contains("demo-agent-implementor"))
        #expect(try agentIds(workspaceId: DemoFixtures.longConversationWorkspaceId)
            == [DemoFixtures.longConversationAgentId] + DemoFixtures.longConversationDelegateIds)
        // The short conversation's workspace has one idle foreground agent,
        // so its row opens straight into the transcript (intent-hq/ios#346).
        #expect(try agentIds(workspaceId: DemoFixtures.shortConversationWorkspaceId)
            == [DemoFixtures.shortConversationAgentId])

        for agentId in [DemoFixtures.longConversationAgentId, DemoFixtures.shortConversationAgentId] {
            let result = DemoFixtures.response(for: "agent.get", params: ["agentId": agentId])
            let dict = try #require(result as? [String: Any])
            let agentDict = try #require(dict["agent"] as? [String: Any])
            #expect(agentDict["id"] as? String == agentId)
            #expect(agentDict["status"] as? String == "idle")
            #expect(agentDict["isBackground"] as? Bool != true)
        }
    }

    /// The delegates are background sub-agents of the coordinator, so the
    /// coordinator stays the workspace's only foreground agent (the
    /// workspace row still auto-opens into its transcript) while the
    /// "Waiting for all" footer has rows to show.
    @Test func longConversationDelegatesAreBackgroundSubAgentsOfTheCoordinator() throws {
        let result = DemoFixtures.response(
            for: "agent.list", params: ["workspaceId": DemoFixtures.longConversationWorkspaceId])
        let dict = try #require(result as? [String: Any])
        let items = try #require(dict["agents"] as? [[String: Any]])
        let agents = items.compactMap { AgentSession.parseAgent($0) }
        #expect(agents.count == items.count)

        let foreground = agents.filter { !$0.isBackground && $0.createdByAgentId == nil }
        #expect(foreground.map(\.id) == [DemoFixtures.longConversationAgentId])
        let delegates = agents.filter { DemoFixtures.longConversationDelegateIds.contains($0.id) }
        #expect(delegates.count == DemoFixtures.longConversationDelegateIds.count)
        #expect(delegates.allSatisfy { $0.isBackground && $0.createdByAgentId == DemoFixtures.longConversationAgentId })
        #expect(delegates.contains { $0.isActive })

        for delegateId in DemoFixtures.longConversationDelegateIds {
            let fetched = DemoFixtures.response(for: "agent.get", params: ["agentId": delegateId])
            let fetchedDict = try #require(fetched as? [String: Any])
            let agentDict = try #require(fetchedDict["agent"] as? [String: Any])
            #expect(agentDict["id"] as? String == delegateId)
        }
    }

    // MARK: - Delayed hooks row for the long conversation

    private func hooks(workspaceId: String?) throws -> [BackgroundHook] {
        var params: [String: Any] = [:]
        if let workspaceId { params["workspaceId"] = workspaceId }
        let result = DemoFixtures.response(for: "hook.list", params: params)
        let dict = try #require(result as? [String: Any])
        let items = try #require(dict["hooks"] as? [[String: Any]])
        let hooks = items.compactMap { BackgroundHook.parseHook($0) }
        #expect(hooks.count == items.count)
        return hooks
    }

    @Test func hookListServesOneActiveHookForTheLongConversationAgent() throws {
        let hooks = try hooks(workspaceId: DemoFixtures.longConversationWorkspaceId)
        let hook = try #require(hooks.first)
        #expect(hooks.count == 1)
        #expect(hook.isActive)
        #expect(hook.agentId == DemoFixtures.longConversationAgentId)
        #expect(hook.workspaceId == DemoFixtures.longConversationWorkspaceId)
        #expect(hook.name == DemoFixtures.longConversationHookName)
        #expect(hook.nextRunAt != nil)
    }

    @Test func hookListIsEmptyForOtherWorkspaces() throws {
        #expect(try hooks(workspaceId: nil).isEmpty)
        #expect(try hooks(workspaceId: "demo-ws-dashboard").isEmpty)
    }

    @Test func hookListDelayComesFromTheLaunchArgumentWhenPresent() {
        #expect(DemoFixtures.hookListDelay(from: ["--demo-data"]) == DemoFixtures.defaultHookListDelay)
        #expect(DemoFixtures.hookListDelay(from: ["--demo-data", "--demo-hook-list-delay-ms=9000"])
            == .milliseconds(9_000))
        #expect(DemoFixtures.hookListDelay(from: ["--demo-hook-list-delay-ms=0"]) == .zero)
        #expect(DemoFixtures.hookListDelay(from: ["--demo-hook-list-delay-ms=abc"])
            == DemoFixtures.defaultHookListDelay)
        #expect(DemoFixtures.hookListDelay(from: ["--demo-hook-list-delay-ms=-5"])
            == DemoFixtures.defaultHookListDelay)
        #expect(DemoFixtures.hookListDelay(from: ["--demo-hook-list-delay-ms=100", "--demo-hook-list-delay-ms=250"])
            == .milliseconds(250))
    }

    @Test func hookListGateIsATriggerFileWhenTheLaunchArgumentNamesOne() {
        #expect(DemoFixtures.hookListGate(from: ["--demo-data"]) == .delay(DemoFixtures.defaultHookListDelay))
        #expect(DemoFixtures.hookListGate(from: ["--demo-data", "--demo-hook-list-delay-ms=9000"])
            == .delay(.milliseconds(9_000)))
        #expect(DemoFixtures.hookListGate(from: ["--demo-hook-list-trigger-file=/tmp/a.trigger"])
            == .triggerFile(URL(fileURLWithPath: "/tmp/a.trigger")))
        // The trigger file wins over a delay; the last non-empty path wins.
        #expect(DemoFixtures.hookListGate(from: [
            "--demo-hook-list-delay-ms=9000",
            "--demo-hook-list-trigger-file=/tmp/a.trigger",
            "--demo-hook-list-trigger-file=/tmp/b.trigger",
            "--demo-hook-list-trigger-file=",
        ]) == .triggerFile(URL(fileURLWithPath: "/tmp/b.trigger")))
        #expect(DemoFixtures.hookListGate(from: ["--demo-hook-list-trigger-file="])
            == .delay(DemoFixtures.defaultHookListDelay))
    }

    @Test func triggerFileGateOpensOnceTheFileExists() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("demo-fixtures-\(UUID().uuidString).trigger")
        defer { try? FileManager.default.removeItem(at: url) }

        let opened = OpenedFlag()
        let gate = Task {
            try await DemoFixtures.wait(for: .triggerFile(url))
            await opened.set()
        }
        // Several poll intervals without the file: still closed.
        try await Task.sleep(for: .milliseconds(400))
        #expect(await opened.value == false)

        try Data().write(to: url)
        // Bounded: a gate that never opens must fail the test, not hang it.
        let watchdog = Task {
            try await Task.sleep(for: .seconds(5))
            gate.cancel()
        }
        try await gate.value
        watchdog.cancel()
        #expect(await opened.value == true)
    }

    private actor OpenedFlag {
        private(set) var value = false
        func set() { value = true }
    }

    @Test func triggerFileGateWaitIsCancellable() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("demo-fixtures-\(UUID().uuidString).never")
        let gate = Task { try await DemoFixtures.wait(for: .triggerFile(url)) }
        gate.cancel()
        await #expect(throws: CancellationError.self) { try await gate.value }
    }

    @Test func onlyTheLongConversationHookListIsGated() {
        let long = ["workspaceId": DemoFixtures.longConversationWorkspaceId]
        #expect(DemoFixtures.responseGate(for: "hook.list", params: long)
            == DemoFixtures.longConversationHookListGate)
        #expect(DemoFixtures.responseGate(for: "hook.list", params: [:]) == nil)
        #expect(DemoFixtures.responseGate(for: "hook.list", params: ["workspaceId": "demo-ws-dashboard"]) == nil)
        #expect(DemoFixtures.responseGate(for: "agent.getConversation", params: long) == nil)
        #expect(DemoFixtures.responseGate(for: "prMonitor.list", params: long) == nil)
    }

    @Test func taskListFixtureParses() throws {
        let result = DemoFixtures.response(for: "task.list", params: [:])
        let dict = try #require(result as? [String: Any])
        let items = try #require(dict["tasks"] as? [[String: Any]])
        let tasks = items.compactMap { WorkspaceTask.parseTask($0) }
        #expect(tasks.count == items.count)
    }

    @Test func noteGetReturnsRequestedNote() throws {
        let result = DemoFixtures.response(
            for: "note.get", params: ["noteId": "demo-note-research"])
        let dict = try #require(result as? [String: Any])
        let noteDict = try #require(dict["note"] as? [String: Any])
        #expect(noteDict["id"] as? String == "demo-note-research")
    }

    @Test func unknownMethodReturnsEmptyDictionary() throws {
        let result = DemoFixtures.response(for: "note.subscribe", params: [:])
        let dict = try #require(result as? [String: Any])
        // No subscriptionId → stores fall back to their legacy fetch paths
        #expect(dict["subscriptionId"] == nil)
        #expect(dict.isEmpty)
    }

    @Test func fixturesContainNoPlaceholderOrSecretContent() throws {
        let payload: [Any] = [
            DemoFixtures.response(for: "workspace.list", params: [:]),
            DemoFixtures.response(for: "note.list", params: [:]),
            DemoFixtures.response(for: "agent.list", params: [:]),
            DemoFixtures.response(
                for: "agent.list", params: ["workspaceId": DemoFixtures.longConversationWorkspaceId]),
            DemoFixtures.response(for: "agent.getConversation", params: [:]),
            DemoFixtures.response(
                for: "agent.getConversation", params: ["agentId": DemoFixtures.longConversationAgentId]),
            DemoFixtures.response(
                for: "hook.list", params: ["workspaceId": DemoFixtures.longConversationWorkspaceId]),
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let text = try #require(String(data: data, encoding: .utf8)).lowercased()
        #expect(!text.contains("lorem"))
        #expect(!text.contains("ipsum"))
        #expect(!text.contains("token"))
        #expect(!text.contains("bearer"))
    }
}
