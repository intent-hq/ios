import Foundation
@testable import Intent
import Testing

@MainActor
struct ConversationGoalViewModelTests {
    private static let goalCapabilities = ConnectionCapabilities(hello: [
        "server": ["protocolVersion": ProtocolFixtures.currentProtocolVersion, "capabilities": ["conversationGoal": 1]]
    ])

    private func makeGoalVM(supported: Bool = true) async -> (viewModel: ConversationViewModel, fake: FakeConnectionManager) {
        let fake = FakeConnectionManager()
        if supported { fake.capabilities = Self.goalCapabilities }
        fake.stubChatSnapshot()
        let suiteName = "ConversationGoalViewModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        let viewModel = ConversationViewModel(
            agentId: "test-agent",
            workspaceId: "test-ws",
            agentName: "Test",
            connection: fake,
            uploadService: AttachmentUploadService(connection: fake),
            optionsStore: CreationOptionsStore(connectionManager: fake),
            persistence: PersistenceManager(defaults: defaults, keychainStorage: EphemeralKeychainStorage())
        )
        await viewModel.store.subscribeLiveChat(agentId: "test-agent", workspaceId: "test-ws")
        return (viewModel, fake)
    }

    private func agentUpdated(_ data: [String: Any]) -> [String: Any] {
        ["event": ["type": "agent:updated", "workspaceId": "test-ws", "data": data] as [String: Any]]
    }

    @Test func goalUIIsHiddenWithoutTheCapability() async {
        let (viewModel, _) = await makeGoalVM(supported: false)
        viewModel.store.goal = "Ship it"
        #expect(viewModel.conversationGoal == nil)
        #expect(!viewModel.routesAsGoalCommand("/goal Ship it"))
    }

    @Test func goalUIShowsTheStoredGoalWithTheCapability() async {
        let (viewModel, _) = await makeGoalVM()
        #expect(viewModel.conversationGoal == nil)
        viewModel.store.goal = "Ship it"
        #expect(viewModel.conversationGoal == "Ship it")
        #expect(viewModel.routesAsGoalCommand("/goal Ship it"))
        #expect(!viewModel.routesAsGoalCommand("/goals Ship it"))
    }

    @Test func agentGetSeedsTheGoalAndAgentUpdatedKeepsItLive() async {
        let (viewModel, fake) = await makeGoalVM()
        let store = viewModel.store
        fake.responseMap["agent.get"] = ["agent": ["id": "test-agent", "name": "Test", "workspaceId": "test-ws", "goal": "Ship it"]]
        await store.fetchAgentStreamingState(agentId: "test-agent")
        #expect(store.goal == "Ship it")

        store.handleStreamEvent("events.event", params: agentUpdated(["agentId": "test-agent", "goal": "Ship the beta"]))
        #expect(store.goal == "Ship the beta")

        store.handleStreamEvent("events.event", params: agentUpdated(["agentId": "test-agent", "pendingQuestionsMessageId": "q1"]))
        #expect(store.goal == "Ship the beta", "An update without goal leaves it alone")

        store.handleStreamEvent("events.event", params: agentUpdated(["agentId": "test-agent", "goal": NSNull()]))
        #expect(store.goal == nil)
        #expect(!fake.paramsForMethod("agent.get").isEmpty)
    }

    @Test func goalCommandSendsWithoutOptimisticBubbleAndClearsComposerOnSuccess() async throws {
        let (viewModel, fake) = await makeGoalVM()
        fake.pendingMethods.insert("agent.sendMessage")
        viewModel.messageText = "/goal Ship it"
        let send = Task { await viewModel.sendGoalCommand("/goal Ship it") }
        try await fake.waitForPendingRequests("agent.sendMessage")

        #expect(viewModel.store.messages.isEmpty, "No optimistic user bubble")
        #expect(viewModel.store.sendAttempts.isEmpty)
        #expect(!viewModel.store.isStreaming, "No thinking state")
        #expect(viewModel.messageText == "/goal Ship it", "The composer keeps the text until the daemon answers")
        let params = try #require(fake.paramsForMethod("agent.sendMessage").first)
        #expect(params["interpretCommands"] as? Bool == true)
        #expect(params["content"] as? String == "/goal Ship it")
        #expect(params["messageId"] == nil)
        #expect(params["workspaceId"] as? String == "test-ws")

        fake.resolvePending("agent.sendMessage", with: [
            "success": true, "queued": false,
            "command": ["name": "goal", "action": "set", "goal": "Ship it", "noticeMessageId": "n1"]
        ] as [String: Any])
        #expect(await send.value)
        #expect(viewModel.messageText.isEmpty)
        #expect(viewModel.store.goal == "Ship it")
        #expect(viewModel.store.messages.isEmpty)
        #expect(!viewModel.store.isStreaming)
        #expect(viewModel.goalError == nil)
    }

    @Test func resultWithoutCommandIsAnOrdinaryDelivery() async {
        let (viewModel, fake) = await makeGoalVM()
        fake.responseMap["agent.sendMessage"] = ["success": true, "queued": false, "messageId": "m1"]
        fake.responseMap["agent.get"] = ["agent": ["id": "test-agent", "name": "Test", "workspaceId": "test-ws", "goal": "Ship it"]]
        let readsBefore = fake.paramsForMethod("agent.get").count
        viewModel.store.goal = "Ship it"
        viewModel.messageText = "/goal Ship the beta"
        #expect(await viewModel.sendGoalCommand("/goal Ship the beta"))
        #expect(viewModel.messageText.isEmpty, "The daemon delivered the text, so the composer clears")
        #expect(viewModel.store.goal == "Ship it", "Only a command result changes the goal")
        #expect(fake.paramsForMethod("agent.get").count == readsBefore + 1, "A delivered message refreshes the daemon's turn state")
        #expect(viewModel.goalError == nil)
    }

    @Test func staleAgentGetDoesNotOverwriteALiveGoalUpdate() async throws {
        let (viewModel, fake) = await makeGoalVM()
        let store = viewModel.store
        fake.pendingMethods.insert("agent.get")
        let refresh = Task { await store.fetchAgentStreamingState(agentId: "test-agent") }
        try await fake.waitForPendingRequests("agent.get")
        store.handleStreamEvent("events.event", params: agentUpdated(["agentId": "test-agent", "goal": "B"]))
        fake.resolvePending("agent.get", with: ["agent": ["id": "test-agent", "name": "Test", "workspaceId": "test-ws", "goal": "A"]] as [String: Any])
        await refresh.value
        #expect(store.goal == "B")
    }

    @Test func staleAgentGetDoesNotRestoreARemovedGoal() async throws {
        let (viewModel, fake) = await makeGoalVM()
        let store = viewModel.store
        store.goal = "A"
        fake.pendingMethods.insert("agent.get")
        let refresh = Task { await store.fetchAgentStreamingState(agentId: "test-agent") }
        try await fake.waitForPendingRequests("agent.get")
        store.handleStreamEvent("events.event", params: agentUpdated(["agentId": "test-agent", "goal": NSNull()]))
        fake.resolvePending("agent.get", with: ["agent": ["id": "test-agent", "name": "Test", "workspaceId": "test-ws", "goal": "A"]] as [String: Any])
        await refresh.value
        #expect(store.goal == nil)
    }

    @Test func aSecondGoalCommandWaitsForTheFirst() async throws {
        let (viewModel, fake) = await makeGoalVM()
        fake.pendingMethods.insert("agent.sendMessage")
        let first = Task { await viewModel.sendGoalCommand("/goal Ship it") }
        try await fake.waitForPendingRequests("agent.sendMessage")
        #expect(viewModel.pendingGoalCommand == "/goal Ship it")
        #expect(!(await viewModel.sendGoalCommand("/goal Something else")))
        fake.resolvePending("agent.sendMessage", with: ["success": true, "queued": false, "command": ["name": "goal", "action": "set", "goal": "Ship it"]] as [String: Any])
        #expect(await first.value)
        #expect(viewModel.pendingGoalCommand == nil)
        #expect(fake.paramsForMethod("agent.sendMessage").count == 1)
    }

    @Test func goalCommandFailureKeepsComposerAndReportsTheDaemonMessage() async {
        let (viewModel, fake) = await makeGoalVM()
        fake.errorMap["agent.sendMessage"] = NSError(
            domain: "WebSocket",
            code: -32_602,
            userInfo: [
                NSLocalizedDescriptionKey: "goal is too long (max 1000 characters)",
                NSError.intentErrorDataCodeKey: "goal-too-long"
            ]
        )
        viewModel.messageText = "/goal too long"
        #expect(!(await viewModel.sendGoalCommand("/goal too long")))
        #expect(viewModel.messageText == "/goal too long")
        #expect(viewModel.goalError == ConversationGoal.tooLongError)
        #expect(viewModel.store.goal == nil)
        #expect(viewModel.store.sendAttempts.isEmpty)
    }

    @Test func goalCommandKeepsNewerTypingAfterSuccess() async throws {
        let (viewModel, fake) = await makeGoalVM()
        fake.pendingMethods.insert("agent.sendMessage")
        viewModel.messageText = "/goal Ship it"
        let send = Task { await viewModel.sendGoalCommand("/goal Ship it") }
        try await fake.waitForPendingRequests("agent.sendMessage")
        viewModel.messageText = "next message"
        fake.resolvePending("agent.sendMessage", with: [
            "success": true, "queued": false,
            "command": ["name": "goal", "action": "set", "goal": "Ship it", "noticeMessageId": "n1"]
        ] as [String: Any])
        #expect(await send.value)
        #expect(viewModel.messageText == "next message")
    }

    @Test func goalCommandWithAttachmentsIsRefusedLocally() async {
        let (viewModel, fake) = await makeGoalVM()
        viewModel.pendingFiles = [PendingFile(url: URL(fileURLWithPath: "/tmp/goal.txt"), displayName: "goal.txt", size: 0)]
        viewModel.messageText = "/goal Ship it"
        #expect(!(await viewModel.sendGoalCommand("/goal Ship it")))
        #expect(viewModel.goalError == ConversationGoal.attachmentsError)
        #expect(viewModel.messageText == "/goal Ship it")
        #expect(!fake.didCallMethod("agent.sendMessage"))
    }

    @Test func duplicateGoalCommandWhileOneIsInFlightIsIgnored() async throws {
        let (viewModel, fake) = await makeGoalVM()
        fake.pendingMethods.insert("agent.sendMessage")
        let first = Task { await viewModel.sendGoalCommand("/goal Ship it") }
        try await fake.waitForPendingRequests("agent.sendMessage")
        #expect(!(await viewModel.sendGoalCommand("/goal Ship it")))
        fake.resolvePending("agent.sendMessage", with: ["success": true, "queued": false, "command": ["name": "goal", "action": "set", "goal": "Ship it"]] as [String: Any])
        #expect(await first.value)
        #expect(fake.paramsForMethod("agent.sendMessage").count == 1)
    }

    @Test func saveGoalCallsSetGoalWithTheTrimmedText() async throws {
        let (viewModel, fake) = await makeGoalVM()
        fake.responseMap["agent.setGoal"] = ["action": "updated", "goal": "Ship the beta", "noticeMessageId": "n2"]
        viewModel.store.goal = "Ship it"
        #expect(await viewModel.saveGoal("  Ship the beta \n") == nil)
        let params = try #require(fake.paramsForMethod("agent.setGoal").first)
        #expect(params["goal"] as? String == "Ship the beta")
        #expect(params["agentId"] as? String == "test-agent")
        #expect(params["workspaceId"] as? String == "test-ws")
        #expect(viewModel.store.goal == "Ship the beta")
        #expect(!fake.didCallMethod("agent.sendMessage"))
    }

    @Test func savingAnEmptyGoalAndRemoveSendNull() async {
        let (viewModel, fake) = await makeGoalVM()
        fake.responseQueueMap["agent.setGoal"] = [
            ["action": "cleared", "goal": NSNull(), "noticeMessageId": "n3"],
            ["action": "unchanged", "goal": NSNull()]
        ]
        viewModel.store.goal = "Ship it"
        #expect(await viewModel.saveGoal("   ") == nil)
        #expect(viewModel.store.goal == nil)
        await viewModel.removeGoal()
        let calls = fake.paramsForMethod("agent.setGoal")
        #expect(calls.count == 2)
        #expect(calls.allSatisfy { $0["goal"] is NSNull })
        #expect(viewModel.goalError == nil)
    }

    @Test func saveGoalLeavesTheLengthCheckToTheDaemon() async {
        let (viewModel, fake) = await makeGoalVM()
        fake.errorMap["agent.setGoal"] = NSError(
            domain: "WebSocket",
            code: -32_602,
            userInfo: [NSLocalizedDescriptionKey: "goal is too long", NSError.intentErrorDataCodeKey: "goal-too-long"]
        )
        let failure = await viewModel.saveGoal(String(repeating: "a", count: ConversationGoal.maximumLength + 1))
        #expect(failure == ConversationGoal.tooLongError)
        #expect(fake.paramsForMethod("agent.setGoal").count == 1)
    }

    @Test func removeOnARetiredAgentExplainsWhy() async {
        let (viewModel, fake) = await makeGoalVM()
        fake.errorMap["agent.setGoal"] = NSError(
            domain: "WebSocket",
            code: -32_602,
            userInfo: [NSLocalizedDescriptionKey: "agent is retired", NSError.intentErrorDataCodeKey: "agent-retired"]
        )
        viewModel.store.goal = "Ship it"
        await viewModel.removeGoal()
        #expect(viewModel.goalError == ConversationGoal.retiredError)
        #expect(viewModel.store.goal == "Ship it")
    }

    @Test func saveGoalFailureKeepsTheGoal() async {
        let (viewModel, fake) = await makeGoalVM()
        fake.errorMap["agent.setGoal"] = NSError(domain: "WebSocket", code: -32_003, userInfo: [NSLocalizedDescriptionKey: "forbidden"])
        viewModel.store.goal = "Ship it"
        let failure = await viewModel.saveGoal("Other")
        #expect(failure == "The goal was not changed. forbidden")
        #expect(viewModel.store.goal == "Ship it")
        await viewModel.removeGoal()
        #expect(viewModel.goalError == "The goal was not changed. forbidden")
    }
}
