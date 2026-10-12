import Foundation
@testable import Intent
import Observation
import Synchronization
import Testing
import UIKit

extension ConversationViewModelTests {
    private static let defaultMarkSeenDebounceMilliseconds = 20
    private static let defaultMarkSeenDebounce: Duration = .milliseconds(defaultMarkSeenDebounceMilliseconds)
    private static let defaultMarkSeenTimeoutMilliseconds = 2000.0
    private static let millisecondsPerSecond = 1000.0
    private static let markSeenPollDelayNanoseconds: UInt64 = 5_000_000

    // MARK: - Image attachment state regression tests

    @Test func regressionCaptureImagesThenClearBeforeSend() async throws {
        // Regression test: the send flow captures images into a local variable
        // and clears pendingImages BEFORE the async network call. This ensures
        // the UI immediately reflects the cleared state while the captured images
        // are still available for the send operation.
        // This mirrors the fix in MessageInputView.sendCurrentMessage().
        let viewModel = makeVM()
        let img1 = try #require(UIImage(systemName: "star"))
        let img2 = try #require(UIImage(systemName: "circle"))
        viewModel.addImage(img1)
        viewModel.addImage(img2)
        #expect(viewModel.pendingImages.count == 2)

        // Simulate the fixed send flow: capture images, then clear pendingImages
        let capturedImages = viewModel.pendingImages
        viewModel.pendingImages.removeAll()

        // pendingImages should be empty immediately (UI updates)
        #expect(viewModel.pendingImages.isEmpty)

        // But the captured images should still be available for the send call
        #expect(capturedImages.count == 2)

        // sendMessage with explicit images works even though pendingImages is
        // empty. With no server, placement fails — and the FAIL-CLOSED restore
        // path (surfacePlacementFailure) re-attaches the captured images so
        // nothing is silently lost.
        await viewModel.sendMessage("test with images", images: capturedImages)

        #expect(viewModel.imagePlacementError != nil)
        #expect(viewModel.pendingImages.count == 2, "captured images restored on failed placement")
    }

    // MARK: - Seen-marker triggers (agent.markSeen, PROTOCOL §5.5)

    /// Fake-backed VM with a short markSeen debounce for trigger tests.
    private func makeSeenVM(debounce: Duration = ConversationViewModelTests.defaultMarkSeenDebounce)
        -> (viewModel: ConversationViewModel, fake: FakeConnectionManager) {
        let viewModel = makeVM()
        let fake = FakeConnectionManager()
        fake.responseMap["agent.sendMessage"] = ["success": true, "queued": false]
        fake.responseMap["agent.markSeen"] = ["success": true] as [String: Any]
        viewModel.store = ConversationStore(connectionManager: fake)
        viewModel.markSeenDebounceDuration = debounce
        return (viewModel, fake)
    }

    /// Poll (yielding the main actor) until `agent.markSeen` has been called
    /// `count` times or the timeout elapses.
    private func waitForMarkSeen(
        _ fake: FakeConnectionManager,
        count: Int = 1,
        timeoutMs: Double = ConversationViewModelTests.defaultMarkSeenTimeoutMilliseconds
    ) async {
        let deadline = Date().addingTimeInterval(timeoutMs / Self.millisecondsPerSecond)
        while Date() < deadline {
            if fake.paramsForMethod("agent.markSeen").count >= count { return }
            try? await Task.sleep(nanoseconds: Self.markSeenPollDelayNanoseconds)
        }
    }

    @Test func turnFinishFiresDebouncedMarkSeenOnceWithNewestPersistedId() async throws {
        let (viewModel, fake) = makeSeenVM()
        viewModel.conversationAppeared()
        viewModel.store.messages = [
            textMessage(role: .user, text: "hi", id: "m1"),
            textMessage(role: .assistant, text: "done", id: "m2")
        ]

        viewModel.store.isStreaming = true
        viewModel.store.isStreaming = false

        await waitForMarkSeen(fake)
        #expect(viewModel.markSeenDebounceTask == nil, "the fired debounce leaves nothing scheduled")
        try await expectNever("second agent.markSeen for a single turn finish") {
            fake.paramsForMethod("agent.markSeen").count > 1
        }
        let params = fake.paramsForMethod("agent.markSeen")
        #expect(params.first?["messageId"] as? String == "m2")
    }

    @Test func turnFinishOffScreenDoesNotMarkSeen() async throws {
        let (viewModel, fake) = makeSeenVM()
        // No conversationAppeared() — the conversation is not on screen.
        viewModel.store.messages = [textMessage(role: .assistant, text: "done", id: "m1")]

        viewModel.store.isStreaming = true
        viewModel.store.isStreaming = false

        #expect(viewModel.markSeenDebounceTask == nil, "no debounce is scheduled off screen")
        // Turn finish is gated on the conversation being on screen.
        try await expectNever("agent.markSeen RPC") { fake.didCallMethod("agent.markSeen") }
    }

    @Test func coveredIPadConversationMarksBoundaryAndLeavesHiddenUpdatesUnread() async throws {
        let (viewModel, fake) = makeSeenVM()
        viewModel.store.messages = [textMessage(role: .assistant, text: "Visible", id: "m1")]
        viewModel.conversationAppeared()
        viewModel.conversationCovered()
        await waitForMarkSeen(fake)
        #expect(fake.paramsForMethod("agent.markSeen").first?["messageId"] as? String == "m1")

        viewModel.store.messages.append(textMessage(role: .assistant, text: "Hidden", id: "m2"))
        viewModel.store.isStreaming = true
        viewModel.store.isStreaming = false
        viewModel.conversationCovered()
        try await expectNever("marking a hidden iPad update seen") {
            fake.paramsForMethod("agent.markSeen").count > 1
        }

        viewModel.conversationAppeared()
        viewModel.store.isStreaming = true
        viewModel.store.isStreaming = false
        await waitForMarkSeen(fake, count: 2)
        #expect(fake.paramsForMethod("agent.markSeen").last?["messageId"] as? String == "m2")
    }

    @Test func turnFinishWhileAppInactiveDoesNotMarkSeen() async throws {
        let (viewModel, fake) = makeSeenVM()
        viewModel.conversationAppeared()
        viewModel.store.messages = [textMessage(role: .assistant, text: "old", id: "m1")]
        viewModel.store.lastSeenMessageId = "m1"
        viewModel.scenePhaseChanged(isActive: false)
        // Let the backgrounding boundary fire settle (it dedupes against the
        // current marker, so no RPC goes out for it).
        try await expectNever("agent.markSeen RPC") { fake.didCallMethod("agent.markSeen") }

        // A turn finishing while backgrounded must not schedule the debounce
        // — otherwise m2 (newer than the marker) would be sent below.
        viewModel.store.messages.append(textMessage(role: .assistant, text: "new", id: "m2"))
        viewModel.store.isStreaming = true
        viewModel.store.isStreaming = false

        #expect(viewModel.markSeenDebounceTask == nil, "no debounce is scheduled while inactive")
        // Turn finish is gated on the app being active.
        try await expectNever("agent.markSeen RPC") { fake.didCallMethod("agent.markSeen") }
    }

    @Test func plainEntryDoesNotMarkSeen() async throws {
        let (viewModel, fake) = makeSeenVM()
        viewModel.store.messages = [textMessage(role: .assistant, text: "old", id: "m1")]

        viewModel.conversationAppeared()

        #expect(viewModel.markSeenDebounceTask == nil, "entry schedules no debounce")
        // Entry never marks seen — the divider anchor must survive.
        try await expectNever("agent.markSeen RPC") { fake.didCallMethod("agent.markSeen") }
    }

    @Test func replacingStoreDetachesPriorStreamingLifecycle() async throws {
        let (viewModel, oldFake) = makeSeenVM()
        let oldStore = viewModel.store
        viewModel.conversationAppeared()
        oldStore.isStreaming = true

        let newFake = FakeConnectionManager()
        newFake.responseMap["agent.markSeen"] = ["success": true] as [String: Any]
        viewModel.store = ConversationStore(connectionManager: newFake)
        oldStore.isStreaming = false

        #expect(viewModel.markSeenDebounceTask == nil, "the detached store schedules no debounce")
        try await expectNever("agent.markSeen on either store") {
            oldFake.didCallMethod("agent.markSeen") || newFake.didCallMethod("agent.markSeen")
        }
    }

    @Test func sendMessageSchedulesDebouncedMarkSeenWithoutFocusGate() async throws {
        let (viewModel, fake) = makeSeenVM()
        // No conversationAppeared() — composing is proof of looking.

        await viewModel.sendMessage("hello")

        await waitForMarkSeen(fake)
        let params = fake.paramsForMethod("agent.markSeen")
        #expect(params.count == 1)
        let optimisticId = try #require(viewModel.messages.last?.id)
        #expect(
            params.first?["messageId"] as? String == optimisticId,
            "the user's own (persisted-id) message is the marker target"
        )
    }

    @Test func failedSendDoesNotScheduleMarkSeen() async throws {
        // Regression (PR #112 review): a failed send delivered nothing, so
        // the seen marker must not advance — markSeen is scheduled only on
        // the sendMessage success path (desktop parity).
        let (viewModel, fake) = makeSeenVM()
        fake.errorMap["agent.sendMessage"] = NSError(domain: "WebSocket", code: -32_000)
        viewModel.store.messages = [textMessage(role: .assistant, text: "unseen", id: "m1")]

        await viewModel.sendMessage("hello")

        #expect(viewModel.markSeenDebounceTask == nil, "a failed send schedules no debounce")
        // A failed send must not schedule the debounced markSeen.
        try await expectNever("agent.markSeen RPC") { fake.didCallMethod("agent.markSeen") }
    }

    @Test func leavingConversationFiresMarkSeenImmediately() async {
        // Debounce far beyond the poll window: a call proves the immediate path.
        let (viewModel, fake) = makeSeenVM(debounce: .seconds(10))
        viewModel.conversationAppeared()
        viewModel.store.messages = [textMessage(role: .assistant, text: "done", id: "m1")]

        viewModel.conversationDisappeared()

        await waitForMarkSeen(fake)
        let params = fake.paramsForMethod("agent.markSeen")
        #expect(params.count == 1)
        #expect(params.first?["messageId"] as? String == "m1")
    }

    @Test func leaveDuringDebounceWindowDropsPendingMarkSeen() async throws {
        let (viewModel, fake) = makeSeenVM(debounce: .milliseconds(200))
        viewModel.conversationAppeared()
        viewModel.store.messages = [textMessage(role: .assistant, text: "done", id: "m1")]
        viewModel.store.isStreaming = true
        viewModel.store.isStreaming = false // schedules the 200ms debounce
        let pendingDebounce = viewModel.markSeenDebounceTask
        #expect(pendingDebounce != nil)

        viewModel.conversationDisappeared() // immediate fire supersedes the debounce
        #expect(viewModel.markSeenDebounceTask == nil, "the debounce is dropped, not left to fire")
        await waitForMarkSeen(fake)
        // A message lands after the boundary; the cancelled debounce must NOT
        // fire a second call targeting it once it unwinds.
        viewModel.store.messages.append(textMessage(role: .assistant, text: "late", id: "m2"))

        await pendingDebounce?.value
        try await expectNever("second agent.markSeen from the dropped debounce") {
            fake.paramsForMethod("agent.markSeen").count > 1
        }
        let params = fake.paramsForMethod("agent.markSeen")
        #expect(params.first?["messageId"] as? String == "m1")
    }

    @Test func backgroundingFiresMarkSeenImmediately() async {
        let (viewModel, fake) = makeSeenVM(debounce: .seconds(10))
        viewModel.conversationAppeared()
        viewModel.store.messages = [textMessage(role: .assistant, text: "done", id: "m1")]

        viewModel.scenePhaseChanged(isActive: false)

        await waitForMarkSeen(fake)
        let params = fake.paramsForMethod("agent.markSeen")
        #expect(params.count == 1)
        #expect(params.first?["messageId"] as? String == "m1")
    }
}

extension ConversationViewModelTests {
    @Test func boundaryDoesNotResendWhenMarkerAlreadyCurrent() async throws {
        let (viewModel, fake) = makeSeenVM()
        viewModel.store.messages = [textMessage(role: .assistant, text: "done", id: "m1")]
        viewModel.store.lastSeenMessageId = "m1"
        viewModel.conversationAppeared()

        viewModel.conversationDisappeared()

        // All triggers funnel through the store's dedupe.
        try await expectNever("agent.markSeen RPC") { fake.didCallMethod("agent.markSeen") }
    }

    // MARK: - Pending files

    /// Writes a real temp file so `addFiles` can resolve name/size via
    /// `resourceValues`. Plain file URLs are not security-scoped, so
    /// `startAccessingSecurityScopedResource()` returning false is exercised
    /// implicitly (no balancing stop is owed).
    private func makeTempFile(name: String, bytes: Int) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try Data(repeating: 0, count: bytes).write(to: url)
        return url
    }

    @Test func addFilesPopulatesDisplayNameAndSize() throws {
        let viewModel = makeVM()
        let url = try makeTempFile(name: "report.pdf", bytes: 1234)

        viewModel.addFiles([url])

        #expect(viewModel.pendingFiles.count == 1)
        #expect(viewModel.pendingFiles[0].url == url)
        #expect(viewModel.pendingFiles[0].displayName == "report.pdf")
        #expect(viewModel.pendingFiles[0].size == 1234)
        #expect(viewModel.pendingFiles[0].formattedSize?.isEmpty == false)
    }

    @Test func addFilesFallsBackToLastPathComponentForUnreadableURL() {
        let viewModel = makeVM()
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-missing.bin")

        viewModel.addFiles([missing])

        #expect(viewModel.pendingFiles.count == 1)
        #expect(viewModel.pendingFiles[0].displayName == missing.lastPathComponent)
        #expect(viewModel.pendingFiles[0].size == nil)
        #expect(viewModel.pendingFiles[0].formattedSize == nil)
    }

    @Test func addFilesSkipsAlreadyPendingURL() throws {
        let viewModel = makeVM()
        let url = try makeTempFile(name: "dup.txt", bytes: 10)

        viewModel.addFiles([url])
        viewModel.addFiles([url, url])

        #expect(viewModel.pendingFiles.count == 1)
    }

    @Test func removePendingFileRemovesCorrectEntry() throws {
        let viewModel = makeVM()
        let first = try makeTempFile(name: "a.txt", bytes: 1)
        let second = try makeTempFile(name: "b.txt", bytes: 2)
        viewModel.addFiles([first, second])

        viewModel.removePendingFile(at: 0)

        #expect(viewModel.pendingFiles.map(\.displayName) == ["b.txt"])
    }

    @Test func removePendingFileIgnoresOutOfBoundsIndex() throws {
        let viewModel = makeVM()
        viewModel.addFiles([try makeTempFile(name: "a.txt", bytes: 1)])

        viewModel.removePendingFile(at: 5)
        viewModel.removePendingFile(at: -1)

        #expect(viewModel.pendingFiles.count == 1)
    }

    @Test func clearPendingFilesEmptiesList() throws {
        let viewModel = makeVM()
        viewModel.addFiles([
            try makeTempFile(name: "a.txt", bytes: 1),
            try makeTempFile(name: "b.txt", bytes: 2)
        ])

        viewModel.clearPendingFiles()

        #expect(viewModel.pendingFiles.isEmpty)
    }

    @Test func hasPendingAttachmentsCoversImagesAndFiles() throws {
        let viewModel = makeVM()
        #expect(!viewModel.hasPendingAttachments)

        viewModel.addFiles([try makeTempFile(name: "a.txt", bytes: 1)])
        #expect(viewModel.hasPendingAttachments)

        viewModel.clearPendingFiles()
        viewModel.pendingImages = [UIImage()]
        #expect(viewModel.hasPendingAttachments)

        viewModel.pendingImages = []
        #expect(!viewModel.hasPendingAttachments)
    }
}
