import AVFoundation
import Foundation
@testable import Intent
import os
import Testing

@MainActor
struct MediaAudioSessionTests {
    @Test func videoAfterDictationRestoresPlaybackAndNextDictationRestoresRecording() async throws {
        let client = RecordingAudioSessionClient()
        let session = MediaAudioSession(client: client)
        let firstDictation = try await session.acquire(.dictation)
        try await session.release(firstDictation)
        let video = try await session.acquire(.playback)
        try await session.release(video)
        let nextDictation = try await session.acquire(.dictation)
        try await session.release(nextDictation)

        // Deactivation does not reset AVAudioSession's category: each consumer
        // must set its own before activation, including after a different use.
        #expect(client.events == [
            .category(.record, .measurement, .duckOthers), .active(true, []),
            .active(false, .notifyOthersOnDeactivation),
            .category(.playback, .moviePlayback, []), .active(true, []),
            .active(false, .notifyOthersOnDeactivation),
            .category(.record, .measurement, .duckOthers), .active(true, []),
            .active(false, .notifyOthersOnDeactivation)
        ])
        #expect(!client.calledOnMainThread)
    }

    @Test(arguments: [true, false])
    func lateCleanupPreservesOtherAudioConsumers(recordingFirst: Bool) async throws {
        let client = RecordingAudioSessionClient()
        let session = MediaAudioSession(client: client)
        let first = try await session.acquire(recordingFirst ? .dictation : .playback)
        let second = try await session.acquire(recordingFirst ? .playback : .dictation)
        #expect(client.events.suffix(2) == [
            .category(.playAndRecord, .measurement, [.duckOthers, .defaultToSpeaker]), .active(true, [])
        ])

        try await session.release(first)
        let expected: RecordingAudioSessionClient.Event = recordingFirst
            ? .category(.playback, .moviePlayback, []) : .category(.record, .measurement, .duckOthers)
        #expect(client.events.last == expected)
        #expect(!client.events.contains(.active(false, .notifyOthersOnDeactivation)))
        let beforeStaleRelease = client.events
        try await session.release(first)
        #expect(client.events == beforeStaleRelease)
        try await session.release(second)
        #expect(client.events.last == .active(false, .notifyOthersOnDeactivation))
    }

    @Test func failedActivationDoesNotLeakAnAudioLease() async throws {
        let client = RecordingAudioSessionClient(failActivation: true)
        let session = MediaAudioSession(client: client)
        await #expect(throws: RecordingAudioSessionClient.ActivationError.self) {
            try await session.acquire(.playback)
        }
        #expect(client.events.last == .active(false, .notifyOthersOnDeactivation))
        let recording = try await session.acquire(.dictation)
        #expect(client.events.suffix(2) == [
            .category(.record, .measurement, .duckOthers), .active(true, [])
        ])
        try await session.release(recording)
        #expect(client.events.last == .active(false, .notifyOthersOnDeactivation))
    }

    @Test func cancelledStartDoesNotActivateAudio() async {
        let client = RecordingAudioSessionClient()
        let session = MediaAudioSession(client: client)
        let attempt = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await session.acquire(.playback)
        }
        await #expect(throws: CancellationError.self) { try await attempt.value }
        #expect(client.events.isEmpty)
    }
}

/// Records only the platform boundary; category selection, lease ownership and
/// cleanup ordering all run in the production session actor.
nonisolated private final class RecordingAudioSessionClient: MediaAudioSessionClient {
    enum Event: Equatable {
        case category(AVAudioSession.Category, AVAudioSession.Mode, AVAudioSession.CategoryOptions)
        case active(Bool, AVAudioSession.SetActiveOptions)
    }

    struct ActivationError: Error {}

    private struct State {
        var events: [Event] = []
        var calledOnMainThread = false
        var failActivation = false
    }

    private let state: OSAllocatedUnfairLock<State>

    init(failActivation: Bool = false) {
        state = OSAllocatedUnfairLock(initialState: State(failActivation: failActivation))
    }

    var events: [Event] { state.withLock { $0.events } }
    var calledOnMainThread: Bool { state.withLock { $0.calledOnMainThread } }

    func setCategory(
        _ category: AVAudioSession.Category,
        mode: AVAudioSession.Mode,
        options: AVAudioSession.CategoryOptions
    ) {
        state.withLock { state in
            state.events.append(.category(category, mode, options))
            state.calledOnMainThread = state.calledOnMainThread || Thread.isMainThread
        }
    }

    func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws {
        try state.withLock { state in
            state.events.append(.active(active, options))
            state.calledOnMainThread = state.calledOnMainThread || Thread.isMainThread
            if active, state.failActivation {
                state.failActivation = false
                throw ActivationError()
            }
        }
    }
}
