import Foundation
@testable import Intent
import Observation
import SwiftUI
import Testing
import UIKit

/// ios#258 measurement harness for transcript decoding. Every chat snapshot
/// page and every block delta arrives as `[[String: Any]]` from the inbound
/// frame parser and is re-serialized to `Data` and run through a
/// `JSONDecoder` to reach the `Codable` models. Per-row decoding paid one
/// `JSONSerialization.isValidJSONObject` walk, one `JSONSerialization.data`
/// and one fresh `JSONDecoder` per message (and per delta block); the batched
/// decoders pay each once per page/delta.
///
/// The harness decodes representative payloads both ways, asserts the outputs
/// are identical, and prints median wall time per payload with an `[ios#258]`
/// prefix for the issue/PR table. Timing is informational — CI simulators are
/// noisy — so the only asserted contract is output parity.
@Suite(.serialized)
struct TranscriptDecodingMeasurementTests {
    private static let iterations = 15
    private static let toolOutputLineCount = 60
    private static let toolOutputLine = "src/Feature/File.swift:42: note: something the tool reported\n"
    private static let deltaMessageCount = 10
    private static let deltaTerminalStride = 4
    private static let secondsPerMinute = 60

    private struct Measurement {
        let label: String
        let items: Int
        let perItemMedian: Duration
        let batchedMedian: Duration

        var markdownRow: String {
            let ratio = Double(perItemMedian.microseconds) / Double(max(batchedMedian.microseconds, 1))
            return "| \(label) | \(items) | \(perItemMedian.milliString) | \(batchedMedian.milliString) "
                + "| \(String(format: "%.2fx", ratio)) |"
        }
    }

    // MARK: - Payloads

    /// One assistant turn shaped like production: thinking, a tool call
    /// whose result carries a multi-line output, then a text answer.
    private static func assistantRow(turn: Int) -> [String: Any] {
        let output = String(repeating: toolOutputLine, count: toolOutputLineCount)
        return [
            "id": "msg-\(turn)-a",
            "role": "assistant",
            "timestamp": "2026-09-17T02:00:\(String(format: "%02d", turn % secondsPerMinute))Z",
            "turnNumber": turn,
            "isStreaming": false,
            "contentBlocks": [
                ["type": "thinking", "text": "Considering the request for turn \(turn) before acting on it."],
                ["type": "tool_use", "name": "read_file", "toolUseId": "tc-\(turn)", "input": ["path": "src/File\(turn).swift"]],
                ["type": "tool_result", "toolUseId": "tc-\(turn)", "output": output, "outputTruncated": false, "outputBytes": output.utf8.count],
                ["type": "text", "text": "Turn \(turn): the file looks fine, moving on to the next step."]
            ],
            "toolCalls": [["id": "tc-\(turn)", "name": "read_file", "status": "completed"]],
            "toolResults": [["toolCallId": "tc-\(turn)", "isError": false, "content": output]],
            "metadata": ["model": "demo", "turn": turn]
        ]
    }

    private static func userRow(turn: Int) -> [String: Any] {
        [
            "id": "msg-\(turn)-u",
            "role": "user",
            "timestamp": "2026-09-17T01:59:\(String(format: "%02d", turn % secondsPerMinute))Z",
            "contentBlocks": [["type": "text", "text": "Please look at file \(turn) and report back."]]
        ]
    }

    /// `turns` user/assistant pairs, i.e. `2 * turns` message rows.
    static func snapshotPage(turns: Int) -> [[String: Any]] {
        (0..<turns).flatMap { [userRow(turn: $0), assistantRow(turn: $0)] }
    }

    /// A streaming delta: `count` block entities spread over ten messages.
    static func blockDelta(count: Int) -> [[String: Any]] {
        (0..<count).map { index in
            let messageId = "msg-\(index % deltaMessageCount)-a"
            let textBlock: [String: Any] = ["type": "text", "text": "streamed chunk \(index) of the answer"]
            let toolBlock: [String: Any] = [
                "id": "\(messageId):\(index)", "type": "tool_use", "name": "grep", "input": ["q": "\(index)"]
            ]
            return [
                "messageId": messageId,
                "role": "assistant",
                "streamingComplete": (index + 1).isMultiple(of: deltaTerminalStride),
                "block": index.isMultiple(of: 2) ? textBlock : toolBlock
            ]
        }
    }

    // MARK: - Timing

    private static func median(of samples: [Duration]) -> Duration {
        samples.sorted()[samples.count / 2]
    }

    private static func time(_ body: () -> Void) -> Duration {
        let clock = ContinuousClock()
        var samples: [Duration] = []
        body() // warm-up
        for _ in 0..<iterations {
            samples.append(clock.measure(body))
        }
        return median(of: samples)
    }

    private static func measure(label: String, items: Int, perItem: () -> Void, batched: () -> Void) {
        let measurement = Measurement(
            label: label, items: items, perItemMedian: time(perItem), batchedMedian: time(batched)
        )
        print("[ios#258] \(measurement.markdownRow)")
    }

    // MARK: - Tests

    @Test(arguments: [10, 100, 500])
    func snapshotPageDecodesIdenticallyPerRowAndBatched(turns: Int) {
        let rows = Self.snapshotPage(turns: turns)
        let perRow = rows.compactMap { ConversationMessage.parseMessage($0) }
        let batched = ConversationMessage.parseMessages(rows)
        #expect(batched == perRow)
        #expect(batched.count == rows.count)
        #expect(batched.allSatisfy { $0.hasReportedContentBlocks })
        Self.measure(
            label: "chat snapshot page",
            items: rows.count,
            perItem: { _ = rows.compactMap { ConversationMessage.parseMessage($0) } },
            batched: { _ = ConversationMessage.parseMessages(rows) }
        )
    }

    @Test(arguments: [8, 64, 256])
    func blockDeltaDecodesIdenticallyPerEntityAndBatched(count: Int) throws {
        let entities = Self.blockDelta(count: count)
        let perEntity = entities.compactMap { SubscriptionPush.ChatBlockEntity(entity: $0) }
        let batched = try #require(SubscriptionPush.DeltaPayload.decodeChatBlocks(added: entities, updated: []))
        #expect(batched.count == perEntity.count)
        #expect(batched.map(\.block) == perEntity.map(\.block))
        #expect(batched.map(\.messageId) == perEntity.map(\.messageId))
        #expect(batched.map(\.streamingComplete) == perEntity.map(\.streamingComplete))
        Self.measure(
            label: "block delta",
            items: entities.count,
            perItem: { _ = entities.compactMap { SubscriptionPush.ChatBlockEntity(entity: $0) } },
            batched: { _ = SubscriptionPush.DeltaPayload.decodeChatBlocks(added: entities, updated: []) }
        )
    }
}

private extension Duration {
    private static let microsecondsPerSecond: Int64 = 1_000_000
    private static let attosecondsPerMicrosecond: Int64 = 1_000_000_000_000
    private static let microsecondsPerMillisecond = 1000.0

    var microseconds: Int64 {
        components.seconds * Self.microsecondsPerSecond + components.attoseconds / Self.attosecondsPerMicrosecond
    }

    var milliString: String {
        String(format: "%.3f ms", Double(microseconds) / Self.microsecondsPerMillisecond)
    }
}

@Suite @MainActor
struct TranscriptRowHeightIntegrationTests {
    private static let rowWidth: CGFloat = 220
    private static let viewportHeight: CGFloat = 480
    private static let retainedHeight: CGFloat = 24
    private static let heightTolerance: CGFloat = 0.5
    private static let cacheDelay = Duration.milliseconds(100)
    private static let shortText = "Short response."
    private static let longText = String(repeating: "A proposal-sensitive wrapped response needs room. ", count: 18)

    @Test func lazyRowCacheConvergesAfterLateGrowthAndShrinkWithoutRecreation() async throws {
        let message = Self.message(id: "stable-cache-row", text: "Stable cache key")
        let source = TranscriptLateTextSource(text: Self.shortText)
        let cache = ConversationTranscriptRowHeightCache(settleDelay: .milliseconds(1))
        let recorder = TranscriptHeightRecorder()
        cache.updateLayoutWidth(Self.rowWidth)
        let host = TranscriptGeometryHost(
            CacheIntegratedTextProbe(
                source: source,
                message: message,
                cache: cache,
                recorder: recorder,
                width: Self.rowWidth
            ),
            size: CGSize(width: Self.rowWidth, height: Self.viewportHeight)
        )
        defer { host.tearDown() }

        try await waitUntil("initial cache and row convergence") {
            Self.cacheAndOuterConverged(cache: cache, message: message, recorder: recorder)
        }
        let initialHeight = try #require(recorder.naturalHeights.last)
        let instanceID = try #require(recorder.instanceID)

        source.text = Self.longText
        host.layout()
        try await waitUntil("late multiline growth convergence") {
            guard let natural = recorder.naturalHeights.last, natural > initialHeight else { return false }
            return Self.cacheAndOuterConverged(cache: cache, message: message, recorder: recorder)
        }
        let grownHeight = try #require(recorder.naturalHeights.last)

        source.text = Self.shortText
        host.layout()
        try await waitUntil("late multiline shrink convergence") {
            guard let natural = recorder.naturalHeights.last, natural < grownHeight else { return false }
            return Self.cacheAndOuterConverged(cache: cache, message: message, recorder: recorder)
        }
        #expect(recorder.appearances == 1)
        #expect(recorder.instanceID == instanceID)
    }

    @Test func messageViewRetainsThenConvergesAtNarrowWidth() async throws {
        let message = Self.message(id: "message-view-row", text: Self.longText)
        let cache = ConversationTranscriptRowHeightCache(settleDelay: Self.cacheDelay)
        let recorder = TranscriptHeightRecorder()
        cache.updateLayoutWidth(Self.rowWidth)
        cache.record(height: Self.retainedHeight, for: message, hydratingBlockIds: [])
        try await waitUntil("retained height cache seed") {
            Self.equal(cache.height(for: message, hydratingBlockIds: []), Self.retainedHeight)
        }
        let coordinator = try Self.makeCoordinator()
        let host = TranscriptGeometryHost(
            MessageViewHeightProbe(
                message: message,
                cache: cache,
                recorder: recorder,
                width: Self.rowWidth
            )
            .environment(coordinator),
            size: CGSize(width: Self.rowWidth, height: Self.viewportHeight)
        )
        defer { host.tearDown() }

        try await waitUntil("natural MessageView height while retained") {
            guard let natural = recorder.naturalHeights.last else { return false }
            return natural > Self.retainedHeight
                && recorder.outerHeights.contains { Self.equal($0, Self.retainedHeight) }
        }
        try await waitUntil("MessageView cache and outer convergence") {
            Self.cacheAndOuterConverged(cache: cache, message: message, recorder: recorder)
        }
        #expect(Self.equal(recorder.widths.last, Self.rowWidth))
        #expect(recorder.appearances == 1)
    }

    /// The extracted modifier must keep its natural-height state when only
    /// streaming changes, and replay it without recreating the lazy row.
    @Test func streamingCompletionReplaysNaturalHeightWithoutRecreation() async throws {
        let message = Self.message(id: "streaming-completion-row", text: Self.shortText)
        let source = TranscriptLateTextSource(text: Self.shortText)
        source.isStreaming = true
        let cache = ConversationTranscriptRowHeightCache(settleDelay: .milliseconds(1))
        let recorder = TranscriptHeightRecorder()
        cache.updateLayoutWidth(Self.rowWidth)
        let host = TranscriptGeometryHost(
            CacheIntegratedTextProbe(
                source: source,
                message: message,
                cache: cache,
                recorder: recorder,
                width: Self.rowWidth
            ),
            size: CGSize(width: Self.rowWidth, height: Self.viewportHeight)
        )
        defer { host.tearDown() }

        try await waitUntil("streaming row convergence") {
            Self.cacheAndOuterConverged(cache: cache, message: message, recorder: recorder)
        }
        let naturalHeight = try #require(recorder.naturalHeights.last)
        let instanceID = try #require(recorder.instanceID)
        let samplesBeforeCompletion = recorder.naturalHeights.count

        source.isStreaming = false
        host.layout()
        try await waitUntil("natural height replay on streaming completion") {
            recorder.naturalHeights.count > samplesBeforeCompletion
        }
        #expect(Self.equal(recorder.naturalHeights.last, naturalHeight))
        #expect(recorder.appearances == 1)
        #expect(recorder.instanceID == instanceID)
    }

    private static func message(id: String, text: String) -> ConversationMessage {
        ConversationMessage(
            id: id,
            role: .assistant,
            contentBlocks: [ContentBlock(id: "text", type: .text, text: text)],
            streamingState: .complete
        )
    }

    private static func cacheAndOuterConverged(
        cache: ConversationTranscriptRowHeightCache,
        message: ConversationMessage,
        recorder: TranscriptHeightRecorder
    ) -> Bool {
        guard let natural = recorder.naturalHeights.last else { return false }
        return equal(cache.height(for: message, hydratingBlockIds: []), natural)
            && equal(recorder.outerHeights.last, natural)
    }

    private static func equal(_ lhs: CGFloat?, _ rhs: CGFloat?) -> Bool {
        guard let lhs, let rhs else { return false }
        return abs(lhs - rhs) <= heightTolerance
    }

    private static func makeCoordinator() throws -> AppCoordinator {
        _ = TestKeychainStorage.installed
        let suiteName = "TranscriptRowHeightIntegrationTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return AppCoordinator(
            workspaceStore: WorkspaceStore(forTesting: true),
            connection: FakeConnectionManager(),
            persistence: PersistenceManager(defaults: defaults, keychainStorage: InMemoryKeychainStorage())
        )
    }

    private func waitUntil(
        _ what: String,
        timeout: TimeInterval = 3,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline {
                Issue.record("timed out waiting for \(what)")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

@Observable
final class TranscriptLateTextSource {
    var text: String
    var isStreaming = false

    init(text: String) {
        self.text = text
    }
}

@MainActor
final class TranscriptHeightRecorder {
    var naturalHeights: [CGFloat] = []
    var outerHeights: [CGFloat] = []
    var widths: [CGFloat] = []
    var appearances = 0
    var instanceID: UUID?
}

private struct CacheIntegratedTextProbe: View {
    let source: TranscriptLateTextSource
    let message: ConversationMessage
    let cache: ConversationTranscriptRowHeightCache
    let recorder: TranscriptHeightRecorder
    let width: CGFloat
    @State private var instanceID = UUID()

    var body: some View {
        ScrollView {
            LazyVStack {
                Text(source.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .modifier(rowHeightFrame)
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                        recordOuterGeometry(size)
                    }
                    .onAppear(perform: recordAppearance)
                    .id(message.id)
            }
        }
        .frame(width: width)
    }

    private var rowHeightFrame: ConversationTranscriptRowHeightFrame {
        ConversationTranscriptRowHeightFrame(
            cachedHeight: cache.height(for: message, hydratingBlockIds: []),
            isStreaming: source.isStreaming
        ) { height in
            recorder.naturalHeights.append(height)
            cache.record(height: height, for: message, hydratingBlockIds: [])
        }
    }

    private func recordOuterGeometry(_ size: CGSize) {
        recorder.outerHeights.append(size.height)
        recorder.widths.append(size.width)
    }

    private func recordAppearance() {
        recorder.appearances += 1
        recorder.instanceID = instanceID
    }
}

private struct MessageViewHeightProbe: View {
    let message: ConversationMessage
    let cache: ConversationTranscriptRowHeightCache
    let recorder: TranscriptHeightRecorder
    let width: CGFloat

    var body: some View {
        ScrollView {
            LazyVStack {
                MessageView(
                    message: message,
                    workspaceId: "workspace",
                    onNavigateToNote: nil,
                    onNavigateToAgent: nil,
                    hydratingBlockIds: [],
                    onHydrateBlock: nil
                )
                .modifier(rowHeightFrame)
                .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                    recordOuterGeometry(size)
                }
                .onAppear { recorder.appearances += 1 }
                .id(message.id)
            }
        }
        .frame(width: width)
    }

    private var rowHeightFrame: ConversationTranscriptRowHeightFrame {
        ConversationTranscriptRowHeightFrame(
            cachedHeight: cache.height(for: message, hydratingBlockIds: [])
        ) { height in
            recorder.naturalHeights.append(height)
            cache.record(height: height, for: message, hydratingBlockIds: [])
        }
    }

    private func recordOuterGeometry(_ size: CGSize) {
        recorder.outerHeights.append(size.height)
        recorder.widths.append(size.width)
    }
}

@MainActor
private final class TranscriptGeometryHost {
    private var controller: UIHostingController<AnyView>?
    private var window: UIWindow?

    init<Content: View>(_ content: Content, size: CGSize) {
        let controller = UIHostingController(rootView: AnyView(content))
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        controller.view.frame = window.bounds
        controller.beginAppearanceTransition(true, animated: false)
        window.addSubview(controller.view)
        window.isHidden = false
        controller.endAppearanceTransition()
        self.controller = controller
        self.window = window
        layout()
    }

    func layout() {
        controller?.view.setNeedsLayout()
        controller?.view.layoutIfNeeded()
    }

    func tearDown() {
        guard let controller, let window else { return }
        controller.beginAppearanceTransition(false, animated: false)
        controller.view.removeFromSuperview()
        window.isHidden = true
        controller.endAppearanceTransition()
        self.controller = nil
        self.window = nil
    }
}
