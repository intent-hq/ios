import Foundation

enum DictationStopReason {
    case recognitionError
    case recognizerFinished
    case sceneInactive
    case send
    case textEdited
    case userTapped
    case viewDisappeared

    var acceptsFinalResult: Bool {
        switch self {
        case .userTapped, .recognizerFinished:
            return true
        case .send, .viewDisappeared, .sceneInactive, .recognitionError, .textEdited:
            return false
        }
    }
}

enum DictationPhase: Equatable {
    case idle
    case recording
    case starting
}

struct DictationStartState: Equatable {
    private(set) var phase: DictationPhase = .idle
    private(set) var generation = 0

    mutating func requestStart() -> Int? {
        guard phase == .idle else { return nil }
        generation += 1
        phase = .starting
        return generation
    }

    func canProceed(_ token: Int) -> Bool {
        phase == .starting && generation == token
    }

    mutating func started(_ token: Int) -> Bool {
        guard canProceed(token) else { return false }
        phase = .recording
        return true
    }

    mutating func abort(_ token: Int) {
        if canProceed(token) { phase = .idle }
    }

    mutating func stopped() {
        phase = .idle
    }
}

enum DictationStopAction: Equatable {
    case cancelAndSever
    case cancelStart
    case finish
    case ignore
    case severOnly

    static func action(for reason: DictationStopReason, phase: DictationPhase) -> Self {
        switch (phase, reason.acceptsFinalResult) {
        case (.starting, _): return .cancelStart
        case (.recording, true): return .finish
        case (.recording, false): return .cancelAndSever
        case (.idle, true): return .ignore
        case (.idle, false): return .severOnly
        }
    }
}

struct DictationTranscript: Equatable {
    let baseText: String
    let insertionOffset: Int

    init(baseText: String, insertionOffset: Int) {
        self.baseText = baseText
        self.insertionOffset = max(0, min(insertionOffset, baseText.utf16.count))
    }

    func merged(with transcription: String) -> String {
        merging(transcription).text
    }

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

struct DictationSession: Equatable {
    private(set) var transcript: DictationTranscript
    private(set) var lastMergedText: String?

    init(baseText: String, insertionOffset: Int?) {
        self.transcript = DictationTranscript(
            baseText: baseText,
            insertionOffset: insertionOffset ?? baseText.utf16.count
        )
    }

    enum MergeOutcome: Equatable {
        case diverged
        case merged(String)
    }

    mutating func apply(
        transcription: String,
        to currentText: String
    ) -> MergeOutcome {
        apply(transcription: transcription, endsSegment: false, to: currentText)
    }

    mutating func apply(
        transcription: String,
        endsSegment: Bool,
        to currentText: String
    ) -> MergeOutcome {
        guard currentText == (lastMergedText ?? transcript.baseText) else {
            return .diverged
        }
        let (merged, caret) = transcript.merging(transcription)
        if endsSegment {
            transcript = DictationTranscript(baseText: merged, insertionOffset: caret)
            lastMergedText = nil
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

@Observable
final class SpeechDictationController {
    private static let recognitionTapBufferSize: AVAudioFrameCount = 1024

    private var startState = DictationStartState()

    var isRecording: Bool { startState.phase == .recording }
    var isActive: Bool { startState.phase != .idle }
    private(set) var unavailabilityHint: String?

    var onTranscriptChange: ((String, Bool) -> Void)?
    var onDidStop: ((DictationStopReason) -> Void)?

    private var audioEngine: AVAudioEngine?
    private var audioLease: UUID?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var segmentGeneration = 0

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
            let lease = try await MediaAudioSession.shared.acquire(.dictation)
            guard startState.canProceed(token), !Task.isCancelled else {
                startState.abort(token)
                try? await MediaAudioSession.shared.release(lease)
                return
            }
            audioLease = lease
            try begin(with: recognizer)
            _ = startState.started(token)
        } catch {
            guard startState.canProceed(token) else { return }
            startState.abort(token)
            teardownAudio()
            recognitionRequest = nil
            recognitionTask = nil
            unavailabilityHint = "Could not start dictation: \(error.localizedDescription)"
        }
    }

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
        let engine = AVAudioEngine()
        audioEngine = engine
        installRecognition(on: engine, with: recognizer)
        engine.prepare()
        try engine.start()
    }

    private func installRecognition(on engine: AVAudioEngine, with recognizer: SFSpeechRecognizer) {
        segmentGeneration += 1
        let generation = segmentGeneration
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        recognitionRequest = request

        let inputNode = engine.inputNode
        inputNode.removeTap(onBus: 0)
        let format = inputNode.outputFormat(forBus: 0)
        // Speech's own API contract is that append(_:) is
        // called from the tap thread, hence the nonisolated(unsafe) capture
        // of the non-Sendable request.
        nonisolated(unsafe) let tapRequest = request
        inputNode.installTap(
            onBus: 0,
            bufferSize: Self.recognitionTapBufferSize,
            format: format
        ) { @Sendable buffer, _ in
            tapRequest.append(buffer)
        }

        recognitionTask = recognizer.recognitionTask(with: request) { @Sendable [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let endsSegment = isFinal || result?.speechRecognitionMetadata != nil
            let failed = error != nil
            Task { @MainActor in
                guard let self, generation == self.segmentGeneration else { return }
                if let text {
                    self.onTranscriptChange?(text, endsSegment)
                }
                if endsSegment, self.isRecording {
                    self.restartSegment()
                } else if failed, self.isRecording {
                    self.stop(reason: .recognitionError)
                }
            }
        }
    }

    private func restartSegment() {
        guard let engine = audioEngine, engine.isRunning,
              let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
            stop(reason: .recognizerFinished)
            return
        }
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        installRecognition(on: engine, with: recognizer)
    }

    private func teardownAudio() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        if let lease = audioLease {
            audioLease = nil
            Task { try? await MediaAudioSession.shared.release(lease) }
        }
    }

    private static func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { @Sendable status in
                continuation.resume(returning: status)
            }
        }
    }
}
#endif
