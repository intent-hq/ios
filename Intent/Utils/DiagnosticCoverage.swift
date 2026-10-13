/// A coverage register, not an exhaustive control-flow proof.
/// Partial families remain in exported pendingFamilies until all owners land.
nonisolated enum DiagnosticCoverage {
    enum Status: String, Codable, Sendable {
        case instrumented, partial, pending
    }

    struct Entry: Sendable {
        let family: DiagnosticFamily
        let status: Status
    }

    static let version = 1
    static let entries: [Entry] = DiagnosticFamily.allCases.map { family in
        Entry(family: family, status: status(for: family))
    }

    /// No identifiers, paths or test names are included in report metadata.
    static var pendingFamilies: [DiagnosticFamily] { entries.filter { $0.status != .instrumented }.map(\.family) }

    private static func status(for family: DiagnosticFamily) -> Status {
        switch family {
        case .app, .connection, .network, .scanner, .trust: .instrumented
        case .pairing, .pdf, .protocolHandling, .subscription, .other: .partial
        default: .pending
        }
    }

    enum Exclusion: String, Codable, CaseIterable, Sendable {
        case backendAuthoredFailures = "backend_authored_failures"
        case benignOptionalAbsence = "benign_optional_absence"
        case expectedCancellation = "expected_cancellation"
        case nativeCrashOrKill = "native_crash_or_kill"
        case notificationDelivery = "notification_delivery"
        case staleCompletion = "stale_completion"
        case userDefaultsDurability = "user_defaults_durability"
    }
}
