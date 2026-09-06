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

/// Pure decision table for `SpeechDictationController.stop(reason:)`,
/// extracted so the stop-after-stop window is unit-testable without Speech.
/// After a graceful stop (`userTapped`) the session is no longer recording
/// but the recognizer may still deliver its final result; a stop request in
/// that window whose reason rejects final results (e.g. `send`) must still
/// sever the transcript callback so the late final cannot resurrect
/// already-consumed text.
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

    static func action(for reason: DictationStopReason, isRecording: Bool) -> DictationStopAction {
        switch (isRecording, reason.acceptsFinalResult) {
        case (true, true): return .finish
        case (true, false): return .cancelAndSever
        case (false, true): return .ignore
        case (false, false): return .severOnly
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
        guard !transcription.isEmpty else { return baseText }
        let splitIndex = String.Index(utf16Offset: insertionOffset, in: baseText)
        let prefix = String(baseText[..<splitIndex])
        let suffix = String(baseText[splitIndex...])

        let needsLeadingSpace = prefix.last.map { !$0.isWhitespace } ?? false
        let needsTrailingSpace = suffix.first.map { !$0.isWhitespace } ?? false
        return prefix
            + (needsLeadingSpace ? " " : "")
            + transcription
            + (needsTrailingSpace ? " " : "")
            + suffix
    }
}

/// Pure merge state for a live dictation session: each transcription applies
/// only while the composer text is exactly what the previous merge produced
/// (or the untouched base before the first one). Any other text means the
/// user typed — or the view model replaced the text — during dictation; the
/// session reports `.diverged` without touching the text so the caller can
/// stop dictation instead of clobbering the edit.
struct DictationSession: Equatable {
    let transcript: DictationTranscript
    /// Text produced by the last applied merge; `nil` before the first one.
    private(set) var lastMergedText: String?

    init(baseText: String, insertionOffset: Int) {
        self.transcript = DictationTranscript(baseText: baseText, insertionOffset: insertionOffset)
    }

    enum MergeOutcome: Equatable {
        /// Replace the composer text with the merged value.
        case merged(String)
        /// `currentText` was edited outside dictation; nothing was applied.
        case diverged
    }

    mutating func apply(transcription: String, to currentText: String) -> MergeOutcome {
        guard currentText == (lastMergedText ?? transcript.baseText) else {
            return .diverged
        }
        let merged = transcript.merged(with: transcription)
        lastMergedText = merged
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
/// MainActor-isolated (target default); recognizer/tap callbacks hop back to
/// the main actor with only Sendable values.
@Observable
final class SpeechDictationController {
    /// True while a dictation session is active.
    private(set) var isRecording = false
    /// Inline hint shown in the composer when dictation is unavailable
    /// (permissions denied, recognizer unavailable, audio failure).
    private(set) var unavailabilityHint: String?

    /// Fires with each partial/final transcription. The Bool is `isFinal`.
    var onTranscriptChange: ((String, Bool) -> Void)?
    /// Fires when a session ends, with the reason it stopped.
    var onDidStop: ((DictationStopReason) -> Void)?

    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    /// Requests permissions and starts a dictation session. Sets
    /// `unavailabilityHint` instead of throwing when dictation cannot start.
    func startRecording() async {
        guard !isRecording else { return }

        let speechStatus = await Self.requestSpeechAuthorization()
        guard speechStatus == .authorized else {
            unavailabilityHint = "Dictation needs Speech Recognition access. Enable it in Settings > Privacy & Security."
            return
        }
        let micGranted = await AVAudioApplication.requestRecordPermission()
        guard micGranted else {
            unavailabilityHint = "Dictation needs Microphone access. Enable it in Settings > Privacy & Security."
            return
        }
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
            unavailabilityHint = "Speech recognition is currently unavailable."
            return
        }

        unavailabilityHint = nil
        do {
            try begin(with: recognizer)
            isRecording = true
        } catch {
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
        switch DictationStopAction.action(for: reason, isRecording: isRecording) {
        case .ignore:
            return
        case .severOnly:
            onTranscriptChange = nil
            recognitionTask?.cancel()
            recognitionTask = nil
            recognitionRequest = nil
            return
        case .finish:
            isRecording = false
            teardownAudio()
            recognitionRequest?.endAudio()
            recognitionTask?.finish()
        case .cancelAndSever:
            isRecording = false
            teardownAudio()
            onTranscriptChange = nil
            recognitionTask?.cancel()
        }
        recognitionRequest = nil
        recognitionTask = nil
        onDidStop?(reason)
    }

    private func begin(with recognizer: SFSpeechRecognizer) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        recognitionRequest = request

        let engine = AVAudioEngine()
        audioEngine = engine
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
        engine.prepare()
        try engine.start()

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failed = error != nil
            Task { @MainActor in
                guard let self else { return }
                if let text {
                    self.onTranscriptChange?(text, isFinal)
                }
                if isFinal, self.isRecording {
                    self.stop(reason: .recognizerFinished)
                } else if failed, self.isRecording {
                    self.stop(reason: .recognitionError)
                }
            }
        }
    }

    private func teardownAudio() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private static func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }
}
#endif
