import AVFAudio
import Foundation

/// Synthesizes the agent-notification chime as a WAV file on disk.
///
/// visionOS emits the notification sound from the source window's scene via
/// RealityKit (`WindowFeedbackSoundEmitter`), which needs a loadable audio
/// file, and the bundle ships no audio assets. The chime (two decaying
/// sine tones) is generated once and cached in the temporary directory.
enum NotificationChime {
    @MainActor
    static func playForegroundSound() async {
        guard let lease = try? await MediaAudioSession.shared.acquire(.notification) else { return }
        defer { Task { try? await MediaAudioSession.shared.release(lease) } }
        guard !Task.isCancelled, let url = fileURL(),
              let player = try? AVAudioPlayer(contentsOf: url), player.play() else { return }
        try? await Task.sleep(for: .seconds(player.duration))
        player.stop()
    }

    /// 16-bit mono PCM.
    private static let sampleRate = 44_100
    private static let duration = 0.6
    private static let riffHeaderByteCount = 44
    private static let riffSizeFieldByteCount = 8
    private static let formatChunkByteCount: UInt32 = 16
    private static let bytesPerSample = 2
    private static let pcmFormat: UInt16 = 1
    private static let channelCount: UInt16 = 1
    private static let bitsPerSample: UInt16 = 16
    private static let firstToneFrequency = 523.25
    private static let secondToneFrequency = 659.25
    private static let secondToneDelay = 0.08
    private static let toneAmplitude = 0.10
    private static let decayRate = 9.0
    private static let attackDuration = 0.018
    private static let fadeDuration = 0.12
    private static let normalizedAmplitudeLimit = 1.0
    private static let int16AmplitudeLimit = 32_766.0

    /// URL of the cached chime WAV, generating it on first use. Nil only
    /// when the file cannot be written.
    static func fileURL() -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("intent-notification-chime-v2.wav")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        do {
            try wavData().write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// Complete WAV bytes (44-byte RIFF header + 16-bit little-endian PCM).
    static func wavData() -> Data {
        let samples = chimeSamples()
        var data = Data(capacity: Self.riffHeaderByteCount + samples.count * Self.bytesPerSample)
        data.append(contentsOf: Array("RIFF".utf8))
        appendUInt32(
            &data,
            UInt32(
                Self.riffHeaderByteCount
                    - Self.riffSizeFieldByteCount
                    + samples.count * Self.bytesPerSample
            )
        )
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        appendUInt32(&data, Self.formatChunkByteCount)
        appendUInt16(&data, Self.pcmFormat)
        appendUInt16(&data, Self.channelCount)
        appendUInt32(&data, UInt32(sampleRate))
        appendUInt32(&data, UInt32(sampleRate * Self.bytesPerSample))
        appendUInt16(&data, UInt16(Self.bytesPerSample))
        appendUInt16(&data, Self.bitsPerSample)
        data.append(contentsOf: Array("data".utf8))
        appendUInt32(&data, UInt32(samples.count * Self.bytesPerSample))
        for sample in samples {
            appendUInt16(&data, UInt16(bitPattern: sample))
        }
        return data
    }

    /// A quiet C5/E5 pair with rounded attacks and a fade to silence.
    static func chimeSamples() -> [Int16] {
        let count = Int(Double(sampleRate) * duration)
        return (0..<count).map { sampleIndex in
            let time = Double(sampleIndex) / Double(sampleRate)
            var value = Self.toneAmplitude
                * sin(2 * .pi * Self.firstToneFrequency * time)
                * exp(-Self.decayRate * time)
                * attack(at: time)
            let secondToneTime = time - Self.secondToneDelay
            if secondToneTime >= 0 {
                value += Self.toneAmplitude
                    * sin(2 * .pi * Self.secondToneFrequency * secondToneTime)
                    * exp(-Self.decayRate * secondToneTime)
                    * attack(at: secondToneTime)
            }
            let fade = min(1, (duration - time) / fadeDuration)
            value *= fade * fade
            let limitedValue = max(
                -Self.normalizedAmplitudeLimit,
                min(Self.normalizedAmplitudeLimit, value)
            )
            return Int16((limitedValue * Self.int16AmplitudeLimit).rounded())
        }
    }

    private static func attack(at time: Double) -> Double {
        let ramp = sin(.pi / 2 * min(1, time / attackDuration))
        return ramp * ramp
    }

    private static func appendUInt16(_ data: inout Data, _ value: UInt16) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    private static func appendUInt32(_ data: inout Data, _ value: UInt32) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
}
