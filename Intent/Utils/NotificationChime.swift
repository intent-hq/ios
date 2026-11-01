import AVFAudio
import Foundation

/// Synthesizes the agent-notification chime as a WAV file on disk.
///
/// visionOS emits the notification sound from the source window's scene via
/// RealityKit (`WindowFeedbackSoundEmitter`), which needs a loadable audio
/// file, and the bundle ships no audio assets. The chime (two decaying
/// sine tones) is generated once and cached in the temporary directory.
enum NotificationChime {
    static var outputVolume: Float { AVAudioSession.sharedInstance().outputVolume }

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
    private static let firstToneFrequency = 880.0
    private static let secondToneFrequency = 1174.66
    private static let secondToneDelay = 0.12
    private static let toneAmplitude = 0.38
    private static let decayRate = 7.0
    private static let normalizedAmplitudeLimit = 1.0
    private static let int16AmplitudeLimit = 32_766.0

    /// URL of the cached chime WAV, generating it on first use. Nil only
    /// when the file cannot be written.
    static func fileURL() -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("intent-notification-chime.wav")
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

    /// Two overlapping decaying sine tones (A5, then D6 120 ms later) — a
    /// short, license-free "ding".
    static func chimeSamples() -> [Int16] {
        let count = Int(Double(sampleRate) * duration)
        return (0..<count).map { sampleIndex in
            let time = Double(sampleIndex) / Double(sampleRate)
            var value = Self.toneAmplitude
                * sin(2 * .pi * Self.firstToneFrequency * time)
                * exp(-Self.decayRate * time)
            let secondToneTime = time - Self.secondToneDelay
            if secondToneTime >= 0 {
                value += Self.toneAmplitude
                    * sin(2 * .pi * Self.secondToneFrequency * secondToneTime)
                    * exp(-Self.decayRate * secondToneTime)
            }
            let limitedValue = max(
                -Self.normalizedAmplitudeLimit,
                min(Self.normalizedAmplitudeLimit, value)
            )
            return Int16((limitedValue * Self.int16AmplitudeLimit).rounded())
        }
    }

    private static func appendUInt16(_ data: inout Data, _ value: UInt16) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    private static func appendUInt32(_ data: inout Data, _ value: UInt32) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
}
