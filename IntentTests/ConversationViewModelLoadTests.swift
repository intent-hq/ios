import Foundation
@testable import Intent
import Testing

extension ConversationViewModelTests {
    // MARK: - Missing-agent detection at load

    /// Bound on load()'s snapshot wait for the never-served cases below.
    private static let shortSnapshotTimeoutMilliseconds = 50
    private static let shortSnapshotTimeout: Duration = .milliseconds(shortSnapshotTimeoutMilliseconds)

    /// Configure the fake with every response load() touches, then override
    /// selected methods with errors.
    private func makeLoadableVM(errors: [String: Error] = [:])
        -> (viewModel: ConversationViewModel, fake: FakeConnectionManager) {
        let fake = FakeConnectionManager()
        let viewModel = ConversationViewModel(
            agentId: "test-agent",
            workspaceId: "test-ws",
            agentName: "Test",
            connection: fake,
            uploadService: AttachmentUploadService(connection: fake),
            optionsStore: CreationOptionsStore(connectionManager: fake)
        )
        fake.responseMap["events.subscribe"] = ["subscriptionId": "sub-streaming"]
        fake.responseMap["events.unsubscribe"] = [:] as [String: Any]
        fake.stubChatSnapshot()
        fake.responseMap["chat.unsubscribe"] = [:] as [String: Any]
        fake.responseMap["agent.get"] = ["agent": ["id": "test-agent", "name": "Test"]] as [String: Any]
        fake.responseMap["agent.getQueue"] = ["queue": []]
        fake.responseMap["agent.getSubscriptions"] = ["subscriptions": [], "delegationGroups": []]
        fake.responseMap["hook.list"] = ["hooks": [] as [[String: Any]]]
        fake.responseMap["prMonitor.list"] = ["monitors": [] as [[String: Any]]]
        for (method, error) in errors {
            fake.errorMap[method] = error
        }
        // load() holds its snapshot wait across a rejected registration up
        // to this bound; keep the never-served cases short.
        viewModel.store.liveTranscript.snapshotTimeout = Self.shortSnapshotTimeout
        return (viewModel, fake)
    }

    private func transcriptRow(_ id: String) -> [String: Any] {
        ["id": id, "role": "assistant", "contentBlocks": [["type": "text", "text": id]]]
    }

    @Test func loadNotFoundRaisesAgentNotFound() async {
        let notFound = NSError(
            domain: "WebSocket",
            code: -32_602,
            userInfo: [
                NSLocalizedDescriptionKey: "unknown agent id: test-agent",
                NSError.intentErrorDataCodeKey: "not-found"
            ]
        )
        let (viewModel, _) = makeLoadableVM(errors: [
            "chat.subscribe": notFound,
            "agent.get": notFound
        ])

        await viewModel.load()

        #expect(viewModel.agentNotFound, "not-found at load must surface agentNotFound")
    }

    @Test func loadBare32602DoesNotRaiseAgentNotFound() async {
        // -32602 without data.code == "not-found" (invalid-params or a legacy
        // daemon omitting data) must NOT read as deletion (docs/PROTOCOL.md §9)
        let bare = NSError(
            domain: "WebSocket",
            code: -32_602,
            userInfo: [NSLocalizedDescriptionKey: "Missing required parameter: agentId"]
        )
        let (viewModel, _) = makeLoadableVM(errors: [
            "chat.subscribe": bare,
            "agent.get": bare
        ])

        await viewModel.load()

        #expect(!viewModel.agentNotFound, "a -32602 without data.code == \"not-found\" must not read as deletion")
    }

    @Test func loadTransientErrorDoesNotRaiseAgentNotFound() async {
        let timeout = NSError(
            domain: "WebSocket",
            code: -2,
            userInfo: [NSLocalizedDescriptionKey: "Request timed out"]
        )
        let (viewModel, _) = makeLoadableVM(errors: [
            "chat.subscribe": timeout,
            "agent.get": timeout
        ])

        await viewModel.load()

        #expect(!viewModel.agentNotFound, "a transient error at load must not read as deletion")
    }

    @Test func loadSuccessLeavesAgentNotFoundFalse() async {
        let (viewModel, _) = makeLoadableVM()

        await viewModel.load()

        #expect(!viewModel.agentNotFound)
    }

    @Test func cancelledLoadDoesNotStartLaterLiveStores() async throws {
        let (viewModel, fake) = makeLoadableVM()
        fake.pendingMethods = ["events.subscribe"]
        let load = Task { await viewModel.load() }
        try await fake.waitForPendingRequests("events.subscribe")

        load.cancel()
        viewModel.conversationDisappeared()
        await load.value

        #expect(fake.paramsForMethod("events.subscribe").count == 1)
        #expect(!fake.didCallMethod("chat.subscribe"))
        #expect(!fake.didCallMethod("hook.list"))
        #expect(!fake.didCallMethod("prMonitor.list"))
        #expect(fake.eventHandlerCount == 0)
    }

    @Test func loadSettlesBeforeTranscriptCanMount() async {
        // Regression (PR #112 review): on first open the transcript view
        // mounts only after load() settles (the loading placeholder renders
        // while isLoading is true), so the entry scroll must be runnable from
        // the transcript's onAppear against already-settled state: isLoading
        // false and the divider anchor latched by the time load() returns.
        let (viewModel, fake) = makeLoadableVM()
        fake.stubChatSnapshot(messages: [
            ["id": "m1", "role": "assistant", "contentBlocks": [["type": "text", "text": "old"]]],
            ["id": "m2", "role": "assistant", "contentBlocks": [["type": "text", "text": "new"]]]
        ])
        fake.responseMap["agent.get"] = [
            "agent": [
                "id": "test-agent",
                "name": "Test",
                "metadata": ["lastSeenMessageId": "m1"]
            ]
        ] as [String: Any]

        await viewModel.load()

        #expect(!viewModel.isLoading, "load() returns with isLoading already settled")
        #expect(viewModel.filteredMessages.count == 2)
        #expect(
            viewModel.newMessagesDividerAnchorId == "m1",
            "the divider anchor is latched before the transcript can mount"
        )
    }

    @Test func loadWaitsForTheRetriedRegistrationsSnapshotBeforeLatching() async throws {
        // A transient rejection of the first chat.subscribe must not settle
        // the load against the empty transcript: the divider anchor latches
        // only once the retried registration's snapshot has applied. The
        // rejection, the retry's ack and the snapshot are each held until
        // load() is seen still parked with the divider unlatched.
        let (viewModel, fake) = makeLoadableVM()
        let transcript = viewModel.store.liveTranscript
        transcript.snapshotTimeout = .seconds(5)
        transcript.initialRetryDelay = .milliseconds(10)
        fake.pendingMethods = ["chat.subscribe"]
        fake.responseMap["agent.get"] = [
            "agent": [
                "id": "test-agent",
                "name": "Test",
                "metadata": ["lastSeenMessageId": "m1"]
            ]
        ] as [String: Any]

        let load = Task { await viewModel.load() }
        try await fake.waitForPendingRequests("chat.subscribe")
        #expect(viewModel.isLoading)
        #expect(!viewModel.hasLatchedNewMessagesDividerAnchor)

        // The rejection returns the registration; load() then parks on the
        // snapshot still owed to the retry, whose registration is held too.
        fake.failPending(
            "chat.subscribe",
            with: NSError(domain: "WebSocket", code: -2, userInfo: [NSLocalizedDescriptionKey: "Request timed out"])
        )
        try await fake.waitForPendingRequests("chat.subscribe")
        try await waitUntil("load() to park on the snapshot") { !transcript.snapshotWaiters.isEmpty }
        #expect(fake.paramsForMethod("chat.subscribe").count == 2, "the retry re-registers the same binding")
        #expect(viewModel.isLoading)
        #expect(!viewModel.hasLatchedNewMessagesDividerAnchor, "the divider stays unlatched across the rejection")

        // "sub-2" has no stubbed snapshot: the ack lands without one.
        fake.resolvePending("chat.subscribe", with: ["subscriptionId": "sub-2"])
        try await waitUntil("the retried registration's handler") { fake.hasSubscriptionHandler(id: "sub-2") }
        #expect(!transcript.snapshotWaiters.isEmpty, "the ack alone does not settle load()")
        #expect(viewModel.isLoading)
        #expect(!viewModel.hasLatchedNewMessagesDividerAnchor, "the divider stays unlatched until the snapshot")

        fake.deliverSubscriptionPush(SubscriptionPush(
            subscriptionId: "sub-2",
            seq: 0,
            conversationSnapshot: [
                ["id": "m1", "role": "assistant", "contentBlocks": [["type": "text", "text": "old"]]],
                ["id": "m2", "role": "assistant", "contentBlocks": [["type": "text", "text": "new"]]]
            ],
            metadata: ["truncated": false, "totalMessages": 2]
        ))
        await load.value

        #expect(viewModel.filteredMessages.map(\.id) == ["m1", "m2"])
        #expect(!viewModel.isLoading)
        #expect(
            viewModel.newMessagesDividerAnchorId == "m1",
            "the divider anchors against the retried registration's snapshot"
        )
    }

    // MARK: - The chat channel is the transcript's only source

    /// Across the transcript's lifecycle — first-open load, the reconnect
    /// re-registration and a seq-gap recovery — every transcript read is a
    /// `chat.subscribe` seq-0 snapshot; `agent.getConversation` is never
    /// fetched (the around-message-id seek is the only remaining caller).
    @Test func transcriptLifecycleReadsOnlyChatSubscribeSnapshots() async throws {
        let (viewModel, fake) = makeLoadableVM()
        fake.stubChatSnapshot(subscriptionId: "sub-1", messages: [transcriptRow("m1")])

        await viewModel.load()
        #expect(viewModel.filteredMessages.map(\.id) == ["m1"])
        #expect(!viewModel.isLoading)
        #expect(fake.hasSubscriptionHandler(id: "sub-1"))

        // Reconnect: the fresh registration's snapshot replaces the transcript.
        fake.stubChatSnapshot(subscriptionId: "sub-2", messages: [transcriptRow("m1"), transcriptRow("m2")])
        fake.simulateConnect()
        try await waitUntil("the reconnect registration's snapshot") {
            viewModel.filteredMessages.map(\.id) == ["m1", "m2"]
        }
        #expect(fake.hasSubscriptionHandler(id: "sub-2"))
        #expect(!fake.hasSubscriptionHandler(id: "sub-1"))

        // Gap: a delta ahead of the expected seq re-registers for a snapshot.
        fake.stubChatSnapshot(
            subscriptionId: "sub-3",
            messages: [transcriptRow("m1"), transcriptRow("m2"), transcriptRow("m3")]
        )
        fake.deliverSubscriptionPush(SubscriptionPush(
            subscriptionId: "sub-2",
            seq: 5,
            delta: SubscriptionPush.DeltaPayload(added: [], updated: [], removedIds: [])
        ))
        try await waitUntil("the gap recovery's snapshot") {
            viewModel.filteredMessages.map(\.id) == ["m1", "m2", "m3"]
        }
        #expect(fake.hasSubscriptionHandler(id: "sub-3"))
        #expect(!fake.hasSubscriptionHandler(id: "sub-2"))
        #expect(fake.paramsForMethod("chat.unsubscribe").compactMap { $0["subscriptionId"] as? String } == ["sub-2"])

        let registrations = fake.paramsForMethod("chat.subscribe").compactMap { $0["agentId"] as? String }
        #expect(registrations == ["test-agent", "test-agent", "test-agent"])
        #expect(!fake.didCallMethod("agent.getConversation"), "the transcript has no other source")
        #expect(viewModel.store.liveTranscript.chatLive)
    }
}
