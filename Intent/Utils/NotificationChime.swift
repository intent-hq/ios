import AVFAudio
import Foundation

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
