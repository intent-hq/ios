import Foundation

/// Owner-only status. A snapshot describes work, never admission or authority.
nonisolated struct DaemonStartupStatus: Equatable, Sendable {
    enum Phase: String, Sendable { case preparing, indexing, finalizing, ready, failed }
    enum FinalizingStep: String, Sendable { case anchors, committing, services }
    struct Progress: Equatable, Sendable {
        let completedNotes: Int
        let totalNotes: Int
        let processedSourceBytes: Int
        let totalSourceBytes: Int
    }

    static let minimumRetryMs = 1000
    static let maximumRetryMs = 30_000
    static let unchangedThresholdMs = 30_000
    let attemptID: String
    let phase: Phase
    let progressAgeMs: Int
    let retryAfterMs: Int?
    let progress: Progress?
    let estimatedRemainingMs: Int?
    let finalizingStep: FinalizingStep?

    static func parse(_ value: Any?) -> Self? {
        guard let row = value as? [String: Any], integer(row["startupStatus"]) == 1,
              let attempt = row["attemptId"] as? String, !attempt.isEmpty,
              let rawPhase = row["phase"] as? String, let phase = Phase(rawValue: rawPhase),
              integer(row["elapsedMs"]) != nil, let phaseElapsed = integer(row["phaseElapsedMs"]),
              let age = integer(row["progressAgeMs"]) else { return nil }
        let terminal = phase == .ready || phase == .failed
        let retry = integer(row["retryAfterMs"])
        guard terminal ? row["retryAfterMs"] == nil && phaseElapsed == 0 && age == 0
            : retry.map({ (minimumRetryMs...maximumRetryMs).contains($0) }) == true else { return nil }
        let step = (row["finalizingStep"] as? String).flatMap(FinalizingStep.init(rawValue:))
        guard phase == .finalizing ? step != nil : row["finalizingStep"] == nil else { return nil }
        if phase == .failed {
            guard let failure = row["failure"] as? [String: Any], failure["code"] as? String == "startup-failed",
                  failure["message"] as? String == "Daemon startup failed. Check daemon logs." else { return nil }
        } else if row["failure"] != nil { return nil }
        let progress = parseProgress(row["progress"])
        guard row["progress"] == nil || progress != nil else { return nil }
        let estimate = integer(row["estimatedRemainingMs"])
        guard row["estimatedRemainingMs"] == nil || (phase == .indexing && estimate != nil) else { return nil }
        return Self(
            attemptID: attempt,
            phase: phase,
            progressAgeMs: age,
            retryAfterMs: retry,
            progress: progress,
            estimatedRemainingMs: estimate,
            finalizingStep: step
        )
    }

    private static func parseProgress(_ value: Any?) -> Progress? {
        guard let row = value as? [String: Any], let completed = integer(row["completedNotes"]),
              let total = integer(row["totalNotes"]), completed <= total,
              let processedBytes = integer(row["processedSourceBytes"]),
              let totalBytes = integer(row["totalSourceBytes"]), processedBytes <= totalBytes else { return nil }
        return Progress(completedNotes: completed, totalNotes: total, processedSourceBytes: processedBytes, totalSourceBytes: totalBytes)
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = ConnectionPrincipal.number(value), ConnectionPrincipal.validClock(number) else { return nil }
        return Int(number)
    }
}

nonisolated enum DaemonStartupState: Equatable, Sendable {
    case failed
    case starting(DaemonStartupStatus?)
    case unavailable
}

nonisolated enum DaemonStartupError: Error {
    case failed
    case notReady(DaemonStartupStatus?)
    case reconnect
}
