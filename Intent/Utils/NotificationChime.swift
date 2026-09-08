import Foundation

/// Synthesizes the agent-notification chime as a WAV file on disk.
///
/// visionOS emits the notification sound from the source window's scene via
/// RealityKit (`WindowFeedbackSoundEmitter`), which needs a loadable audio
/// file — the non-spatial system sound id (1152) played elsewhere has no
/// file API, and the bundle ships no audio assets. The chime (two decaying
/// sine tones) is generated once and cached in the temporary directory.
enum NotificationChime {
    /// 16-bit mono PCM.
    private static let sampleRate = 44_100
    private static let duration = 0.6

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
        var data = Data(capacity: 44 + samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8))
        appendUInt32(&data, UInt32(36 + samples.count * 2))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        appendUInt32(&data, 16)                       // fmt chunk size
        appendUInt16(&data, 1)                        // PCM
        appendUInt16(&data, 1)                        // mono
        appendUInt32(&data, UInt32(sampleRate))
        appendUInt32(&data, UInt32(sampleRate * 2))   // byte rate
        appendUInt16(&data, 2)                        // block align
        appendUInt16(&data, 16)                       // bits per sample
        data.append(contentsOf: Array("data".utf8))
        appendUInt32(&data, UInt32(samples.count * 2))
        for sample in samples {
            appendUInt16(&data, UInt16(bitPattern: sample))
        }
        return data
    }

    /// Two overlapping decaying sine tones (A5, then D6 120 ms later) — a
    /// short, license-free "ding".
    static func chimeSamples() -> [Int16] {
        let count = Int(Double(sampleRate) * duration)
        return (0..<count).map { i in
            let t = Double(i) / Double(sampleRate)
            var value = 0.38 * sin(2 * .pi * 880.0 * t) * exp(-7 * t)
            let t2 = t - 0.12
            if t2 >= 0 {
                value += 0.38 * sin(2 * .pi * 1174.66 * t2) * exp(-7 * t2)
            }
            return Int16((max(-1.0, min(1.0, value)) * 32_766.0).rounded())
        }
    }

    private static func appendUInt16(_ data: inout Data, _ value: UInt16) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    private static func appendUInt32(_ data: inout Data, _ value: UInt32) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
}
