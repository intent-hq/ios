import Foundation

/// Why a dictation session stopped. Determines whether a final recognition
/// result that arrives after the stop should still be applied to the text.
enum DictationStopReason {
    /// The user tapped the mic button to end dictation.
    case userTapped
    /// The message was sent; the composer text was consumed.
    case send
    /// The composer view left the screen.
    case viewDisappeared
    /// The scene became inactive (e.g. the user looked away / app backgrounded).
    case sceneInactive
    /// The recognizer reported an error.
    case recognitionError
    /// The recognizer delivered a final result on its own (e.g. after silence).
    case recognizerFinished
    /// The composer text was edited outside dictation (typed, or replaced by
    /// the view model). The edit wins; a late final must not clobber it.
    case textEdited

    /// Whether a final transcription arriving after this stop should still
    /// replace the partial text. Deliberate endings keep the (usually more
    /// accurate) final result; interruptions must not resurrect text.
    var acceptsFinalResult: Bool {
        switch self {
        case .userTapped, .recognizerFinished:
            return true
        case .send, .viewDisappeared, .sceneInactive, .recognitionError, .textEdited:
            return false
        }
    }
}

/// Lifecycle phase of the dictation controller. `starting` covers the window
/// between the mic tap and the audio engine actually running, while
/// `startRecording()` awaits the permission prompts.
enum DictationPhase: Equatable {
    case idle
    case starting
    case recording
}

/// Pure start-window state for `SpeechDictationController`, extracted so the
/// authorization race is unit-testable without Speech. `startRecording()`
/// awaits permission prompts before any audio starts; a stop during that
/// window (second tap, view disappeared, scene inactive, send) must cancel
/// the pending start so `begin` never runs. Each start carries a generation
/// token: it may only proceed past an await while the machine is still
/// starting *that same attempt* — a cancel followed by a fresh start
/// invalidates the older pending one.
struct DictationStartState: Equatable {
    private(set) var phase: DictationPhase = .idle
    private(set) var generation = 0

    /// Begins a new start attempt (idle → starting) and returns its token;
    /// `nil` when a session is already starting or recording.
    mutating func requestStart() -> Int? {
        guard phase == .idle else { return nil }
        generation += 1
        phase = .starting
        return generation
    }

    /// Whether the start attempt `token` may proceed past an await.
    func canProceed(_ token: Int) -> Bool {
        phase == .starting && generation == token
    }

    /// The attempt `token` reached recording; false if it was cancelled.
    mutating func started(_ token: Int) -> Bool {
        guard canProceed(token) else { return false }
        phase = .recording
        return true
    }

    /// The attempt `token` failed (permission denied, engine error).
    mutating func abort(_ token: Int) {
        if canProceed(token) { phase = .idle }
    }

    /// A stop arrived: back to idle from any phase.
    mutating func stopped() {
        phase = .idle
    }
}

/// Pure decision table for `SpeechDictationController.stop(reason:)`,
/// extracted so the stop-after-stop window is unit-testable without Speech.
/// After a graceful stop (`userTapped`) the session is no longer recording
/// but the recognizer may still deliver its final result; a stop request in
/// that window whose reason rejects final results (e.g. `send`) must still
/// sever the transcript callback so the late final cannot resurrect
/// already-consumed text. A stop while a start is pending (awaiting
/// permissions) cancels the start before any audio begins.
enum DictationStopAction: Equatable {
    /// No active session and the reason keeps final results flowing: no-op.
    case ignore
    /// End the active session, letting the recognizer deliver its final.
    case finish
    /// End the active session, cancel outright and sever the callback.
    case cancelAndSever
    /// No active session, but the transcript callback must still be severed
    /// and any lingering recognition task cancelled.
    case severOnly
    /// A start is pending: cancel it so `begin` never runs, and sever any
    /// recognition lingering from an earlier graceful stop.
    case cancelStart

    static func action(for reason: DictationStopReason, phase: DictationPhase) -> DictationStopAction {
        switch (phase, reason.acceptsFinalResult) {
        case (.starting, _): return .cancelStart
        case (.recording, true): return .finish
        case (.recording, false): return .cancelAndSever
        case (.idle, true): return .ignore
        case (.idle, false): return .severOnly
        }
    }
}

/// Pure merge logic for live dictation: captures the composer text and caret
/// position when dictation starts, then replaces the previously inserted
/// partial transcription with each newer one at that insertion point.
/// Offsets are UTF-16 code units (NSRange semantics, matching
/// `UITextView.selectedRange`).
struct DictationTranscript: Equatable {
    /// Composer text at the moment dictation started.
    let baseText: String
    /// Caret offset (UTF-16) in `baseText` where dictation inserts.
    let insertionOffset: Int

    init(baseText: String, insertionOffset: Int) {
        self.baseText = baseText
        self.insertionOffset = max(0, min(insertionOffset, baseText.utf16.count))
    }

    /// `baseText` with `transcription` inserted at `insertionOffset`,
    /// separated by single spaces from adjacent non-whitespace text.
    func merged(with transcription: String) -> String {
        merging(transcription).text
    }

    /// `merged(with:)` plus the UTF-16 offset just past the inserted
    /// transcription (before any trailing separator) — where the caret
    /// belongs after the insertion, and where a committed segment's
    /// successor inserts.
    func merging(_ transcription: String) -> (text: String, caretOffset: Int) {
        guard !transcription.isEmpty else { return (baseText, insertionOffset) }
        let splitIndex = String.Index(utf16Offset: insertionOffset, in: baseText)
        let prefix = String(baseText[..<splitIndex])
        let suffix = String(baseText[splitIndex...])

        let needsLeadingSpace = prefix.last.map { !$0.isWhitespace } ?? false
        let needsTrailingSpace = suffix.first.map { !$0.isWhitespace } ?? false
        let head = prefix + (needsLeadingSpace ? " " : "") + transcription
        let text = head + (needsTrailingSpace ? " " : "") + suffix
        return (text, head.utf16.count)
    }
}

/// Pure merge state for a live dictation session: each transcription applies
/// only while the composer text is exactly what the previous merge produced
/// (or the untouched base before the first one). Any other text means the
/// user typed — or the view model replaced the text — during dictation; the
/// session reports `.diverged` without touching the text so the caller can
/// stop dictation instead of clobbering the edit.
///
/// The recognizer's transcript is cumulative only within a *segment*: after
/// a silence pause it finishes the utterance (`isFinal`, or a result
/// carrying `speechRecognitionMetadata`) and the next partial's transcript
/// starts over from the new utterance. A segment-ending transcription is
/// therefore committed — folded into the base with the insertion point
/// moved past it — so the next utterance appends instead of replacing
/// previously dictated text.
struct DictationSession: Equatable {
    private(set) var transcript: DictationTranscript
    /// Text produced by the last applied merge; `nil` before the first one
    /// (and again right after a segment commit).
    private(set) var lastMergedText: String?
    /// The transcription folded into the base by the last segment commit; a
    /// final result re-delivering it verbatim is dropped, not applied again.
    private(set) var lastCommittedSegment: String?

    /// `insertionOffset: nil` means no caret has been observed yet (a
    /// programmatically restored draft never fires a selection change) and
    /// inserts at the end of `baseText`.
    init(baseText: String, insertionOffset: Int?) {
        self.transcript = DictationTranscript(
            baseText: baseText,
            insertionOffset: insertionOffset ?? baseText.utf16.count)
    }

    enum MergeOutcome: Equatable {
        /// Replace the composer text with the merged value.
        case merged(String)
        /// `currentText` was edited outside dictation; nothing was applied.
        case diverged
    }

    /// Merges `transcription` into `currentText`. `endsSegment` marks a
    /// transcription that completes the recognizer's current utterance
    /// (a final result, or one carrying recognition metadata after a
    /// pause): the merge is committed so subsequent transcriptions append
    /// after it instead of replacing it.
    mutating func apply(
        transcription: String,
        endsSegment: Bool = false,
        to currentText: String
    ) -> MergeOutcome {
        guard currentText == (lastMergedText ?? transcript.baseText) else {
            return .diverged
        }
        // A late final can re-deliver the segment that was already committed
        // (e.g. endAudio after a pause with no new speech); a genuinely
        // repeated utterance arrives as a partial first, so only a
        // segment-ending duplicate is dropped.
        if endsSegment, lastMergedText == nil, transcription == lastCommittedSegment {
            return .merged(currentText)
        }
        let (merged, caret) = transcript.merging(transcription)
        if endsSegment {
            transcript = DictationTranscript(baseText: merged, insertionOffset: caret)
            lastMergedText = nil
            lastCommittedSegment = transcription
        } else {
            lastMergedText = merged
        }
        return .merged(merged)
    }
}

#if os(visionOS)
import AVFoundation
import Observation
import Speech

/// visionOS-only live dictation: streams microphone audio through
/// `AVAudioEngine` into `SFSpeechRecognizer` (on-device when supported) and
/// delivers partial and final transcriptions via callbacks. All state is
/// MainActor-isolated (target default). Closures handed to AVFoundation /
/// Speech run off the main queue (realtime audio thread, Speech-owned
/// queue), so they are explicitly `@Sendable` — never MainActor-inferred —
/// and hop back to the main actor with only Sendable values.
@Observable
final class SpeechDictationController {
    /// Start-window state machine (idle / starting / recording).
    private var startState = DictationStartState()

    /// True while audio is actually being captured and recognized.
    var isRecording: Bool { startState.phase == .recording }
    /// True from the mic tap on — including the starting window while
    /// permission prompts are pending. The mic button shows this as active
    /// so a second tap during the window cancels the pending start.
    var isActive: Bool { startState.phase != .idle }
    /// Inline hint shown in the composer when dictation is unavailable
    /// (permissions denied, recognizer unavailable, audio failure).
    private(set) var unavailabilityHint: String?

    /// Fires with each partial/final transcription. The Bool marks a
    /// segment-ending transcription (the recognizer finished the utterance
    /// after a pause, or delivered the session's final result): the caller
    /// must commit it, because the next transcript starts over from the
    /// following utterance.
    var onTranscriptChange: ((String, Bool) -> Void)?
    /// Fires when a session ends, with the reason it stopped.
    var onDidStop: ((DictationStopReason) -> Void)?

    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    /// Requests permissions and starts a dictation session. Sets
    /// `unavailabilityHint` instead of throwing when dictation cannot start.
    /// The starting phase is entered synchronously before the first await;
    /// after each await the start proceeds only while its token is still
    /// current — a `stop(reason:)` during the window cancels it and `begin`
    /// never runs.
    func startRecording() async {
        guard let token = startState.requestStart() else { return }

        let speechStatus = await Self.requestSpeechAuthorization()
        guard startState.canProceed(token) else { return }
        guard speechStatus == .authorized else {
            startState.abort(token)
            unavailabilityHint = "Dictation needs Speech Recognition access. Enable it in Settings > Privacy & Security."
            return
        }
        let micGranted = await AVAudioApplication.requestRecordPermission()
        guard startState.canProceed(token) else { return }
        guard micGranted else {
            startState.abort(token)
            unavailabilityHint = "Dictation needs Microphone access. Enable it in Settings > Privacy & Security."
            return
        }
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
            startState.abort(token)
            unavailabilityHint = "Speech recognition is currently unavailable."
            return
        }

        unavailabilityHint = nil
        do {
            try begin(with: recognizer)
            _ = startState.started(token)
        } catch {
            startState.abort(token)
            teardownAudio()
            recognitionRequest = nil
            recognitionTask = nil
            unavailabilityHint = "Could not start dictation: \(error.localizedDescription)"
        }
    }

    /// Ends the active session. Graceful reasons (`acceptsFinalResult`) let
    /// the recognizer deliver its final transcription; interruptions cancel
    /// outright and sever the transcript callback so late results are dropped.
    /// After a graceful stop, an interrupting stop (e.g. `send` before the
    /// final arrived) still severs the callback and cancels the lingering
    /// task so the late final cannot resurrect consumed text.
    func stop(reason: DictationStopReason) {
        switch DictationStopAction.action(for: reason, phase: startState.phase) {
        case .ignore:
            return
        case .severOnly:
            onTranscriptChange = nil
            recognitionTask?.cancel()
            recognitionTask = nil
            recognitionRequest = nil
            return
        case .cancelStart:
            // No engine or recognizer exists yet for the pending start; the
            // phase change makes its token stale so begin never runs. Sever
            // anything lingering from an earlier graceful stop.
            startState.stopped()
            onTranscriptChange = nil
            recognitionTask?.cancel()
            recognitionTask = nil
            recognitionRequest = nil
            onDidStop?(reason)
            return
        case .finish:
            startState.stopped()
            teardownAudio()
            recognitionRequest?.endAudio()
            recognitionTask?.finish()
        case .cancelAndSever:
            startState.stopped()
            teardownAudio()
            onTranscriptChange = nil
            recognitionTask?.cancel()
        }
        recognitionRequest = nil
        recognitionTask = nil
        onDidStop?(reason)
    }

    private func begin(with recognizer: SFSpeechRecognizer) throws {
        // Dictation only records; .record + .measurement + .duckOthers is
        // Apple's dictation configuration. Activation must precede
        // engine.start(); teardownAudio() deactivates.
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let engine = AVAudioEngine()
        audioEngine = engine
        installRecognition(on: engine, with: recognizer)
        engine.prepare()
        try engine.start()
    }

    /// Creates a recognition request + task and taps `engine`'s input into
    /// it. Called by `begin`, and again by `restartSegment` when the
    /// recognizer delivers a final result mid-session.
    private func installRecognition(on engine: AVAudioEngine, with recognizer: SFSpeechRecognizer) {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        recognitionRequest = request

        let inputNode = engine.inputNode
        inputNode.removeTap(onBus: 0)
        let format = inputNode.outputFormat(forBus: 0)
        // The tap runs on the realtime audio thread, so it must be @Sendable
        // (a MainActor-inferred closure aborts with a dispatch queue
        // assertion there). Speech's own API contract is that append(_:) is
        // called from the tap thread, hence the nonisolated(unsafe) capture
        // of the non-Sendable request.
        nonisolated(unsafe) let tapRequest = request
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { @Sendable buffer, _ in
            tapRequest.append(buffer)
        }

        // The result handler runs on a Speech-owned queue: extract only
        // Sendable values there, then hop to the main actor for all state.
        recognitionTask = recognizer.recognitionTask(with: request) { @Sendable [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            // On-device recognition finishes an utterance after a silence
            // pause with a metadata-carrying result (no isFinal); the next
            // partial's transcript starts over from the new utterance, so
            // the finished one must be committed.
            let endsSegment = isFinal || result?.speechRecognitionMetadata != nil
            let failed = error != nil
            Task { @MainActor in
                guard let self else { return }
                if let text {
                    self.onTranscriptChange?(text, endsSegment)
                }
                if isFinal, self.isRecording {
                    self.restartSegment()
                } else if failed, self.isRecording {
                    self.stop(reason: .recognitionError)
                }
            }
        }
    }

    /// The recognizer delivered a final result on its own while still
    /// recording (e.g. it ended the session after silence). The engine is
    /// still running: start a fresh recognition segment so one mic tap
    /// survives pauses — the finished segment was already committed via the
    /// segment-ending callback. Falls back to a normal recognizer-finished
    /// stop when a new segment cannot start; the committed text means a
    /// re-tap appends instead of replacing.
    private func restartSegment() {
        guard let engine = audioEngine, engine.isRunning,
              let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
            stop(reason: .recognizerFinished)
            return
        }
        // The old task already finished (isFinal is its last result).
        recognitionTask = nil
        recognitionRequest = nil
        installRecognition(on: engine, with: recognizer)
    }

    private func teardownAudio() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private static func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            // Invoked on an arbitrary queue; must not be MainActor-inferred.
            SFSpeechRecognizer.requestAuthorization { @Sendable status in
                continuation.resume(returning: status)
            }
        }
    }
}
#endif
