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

    /// Whether a final transcription arriving after this stop should still
    /// replace the partial text. Deliberate endings keep the (usually more
    /// accurate) final result; interruptions must not resurrect text.
    var acceptsFinalResult: Bool {
        switch self {
        case .userTapped, .recognizerFinished:
            return true
        case .send, .viewDisappeared, .sceneInactive, .recognitionError:
            return false
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
    func stop(reason: DictationStopReason) {
        guard isRecording else { return }
        isRecording = false
        teardownAudio()

        if reason.acceptsFinalResult {
            recognitionRequest?.endAudio()
            recognitionTask?.finish()
        } else {
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
