import Foundation
import Synchronization

/// Synchronous, bounded ingress for callbacks. One independent worker drains
/// the buffer; no Task per event and no file I/O while holding the intake lock.
nonisolated final class DiagnosticStore: Sendable {
    static let shared = DiagnosticStore()

    struct Scope: Sendable {
        // DiagnosticIntake needs same-file access; broader access would allow fabricated source sessions.
        // swiftlint:disable:next strict_fileprivate
        fileprivate let session: UUID
        // DiagnosticIntake allocates ordinals in this file; callers must not fabricate source IDs.
        // swiftlint:disable:next strict_fileprivate
        fileprivate let ordinal: UInt64
    }

    private let intake: DiagnosticIntake
    private let writer: DiagnosticWriter

    convenience init() {
        self.init(storage: DiagnosticFileStorage.applicationStorage)
    }

    /// Internal dependency injection. Production uses shared, with fixed limits.
    init(
        storage: any DiagnosticStorage,
        limits: DiagnosticLimits = DiagnosticLimits(),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        let intake = DiagnosticIntake(limits: limits, clock: clock)
        self.intake = intake
        writer = DiagnosticWriter(storage: storage, intake: intake, limits: limits, clock: clock)
        scheduleDrain()
    }

    /// Never pass a backend/scene/request ID: scopes are allocated here and
    /// only have meaning within this launch. Rotation does not reuse ordinals.
    func makeScope() -> Scope? { intake.makeScope() }

    @discardableResult
    func record(_ event: DiagnosticEvent, scope: Scope? = nil) -> Bool {
        let accepted = intake.append(event, scope: scope)
        scheduleDrain()
        return accepted
    }

    /// Flushes all events admitted before this call reaches the writer. Returns
    /// a value snapshot, never the history file's unsanitized bytes or URL.
    func snapshot() async -> DiagnosticSnapshot { await writer.snapshot() }

    /// Clear linearizes at the writer: already queued events are discarded;
    /// events admitted after that point are new history. False means deletion
    /// could not be confirmed (for example, protected files before unlock).
    func clearHistory() async -> Bool { await writer.clearHistory() }

    /// One pinned, fixed-entry ZIP workspace. The sharing layer must end the
    /// lease after its consumer finishes. Orphans are deleted on next launch.
    func beginReport() async -> DiagnosticReport? { await writer.beginReport() }
    func endReport(_ report: DiagnosticReport) async -> Bool { await writer.endReport(report) }

    func prepareExport(reviewing snapshot: DiagnosticSnapshot) async -> DiagnosticExportResult {
        await writer.prepareExport(reviewing: snapshot)
    }

    private func scheduleDrain() {
        guard intake.scheduleWorker() else { return }
        let writer = writer
        // Deliberately independent of UI cancellation, priority and task locals.
        Task.detached(priority: .utility) { await writer.drain() }
    }
}

nonisolated struct DiagnosticReport: Sendable {
    private let token: UUID
    let snapshot: DiagnosticSnapshot
    let directory: URL
    var archiveURL: URL { directory.appendingPathComponent("diagnostics.zip") }

    private init(snapshot: DiagnosticSnapshot, directory: URL) {
        token = UUID()
        self.snapshot = snapshot
        self.directory = directory
    }
}

/// Lock covers only bounded value operations, never storage or suspension.
nonisolated final class DiagnosticIntake: Sendable {
    private struct State {
        var records: [DiagnosticRecord] = []
        var workerScheduled = false
        var nextSequence: UInt64 = 0
        var nextScope: UInt64 = 0
        var overflow: UInt64 = 0
        var invalidScope: UInt64 = 0
    }

    private let state = Mutex(State())
    private let session = UUID()
    private let limits: DiagnosticLimits
    private let clock: @Sendable () -> Date

    init(limits: DiagnosticLimits, clock: @escaping @Sendable () -> Date) {
        self.limits = limits
        self.clock = clock
    }

    func makeScope() -> DiagnosticStore.Scope? {
        state.withLock { state in
            guard state.nextScope < UInt64.max else { return nil }
            state.nextScope += 1
            return DiagnosticStore.Scope(session: session, ordinal: state.nextScope)
        }
    }

    func append(_ event: DiagnosticEvent, scope: DiagnosticStore.Scope?) -> Bool {
        state.withLock { state in
            guard scope == nil || scope?.session == session else {
                state.invalidScope = Self.increment(state.invalidScope)
                return false
            }
            guard state.nextSequence < UInt64.max else {
                state.overflow = Self.increment(state.overflow)
                return false
            }
            let timestamp = Date(timeIntervalSince1970: clock().timeIntervalSince1970.rounded(.down))
            state.nextSequence += 1
            let record = DiagnosticRecord(
                session: session,
                sequence: state.nextSequence,
                scope: scope?.ordinal,
                event: event,
                firstTimestamp: timestamp,
                lastTimestamp: timestamp
            )
            if let last = state.records.last, last.canMerge(record),
               timestamp.timeIntervalSince(last.firstTimestamp) < limits.age {
                state.records[state.records.count - 1].count += 1
                state.records[state.records.count - 1].lastTimestamp = timestamp
                return true
            }
            guard state.records.count < limits.pending else {
                state.overflow = Self.increment(state.overflow)
                return false
            }
            state.records.append(record)
            return true
        }
    }

    func scheduleWorker() -> Bool {
        state.withLock { state in
            guard !state.workerScheduled else { return false }
            state.workerScheduled = true
            return true
        }
    }

    func take() -> [DiagnosticRecord] {
        state.withLock { state in
            let batch = state.records
            state.records = []
            return batch
        }
    }

    func finishBatch() -> Bool {
        state.withLock { state in
            if !state.records.isEmpty { return false }
            state.workerScheduled = false
            return true
        }
    }

    func losses() -> (overflow: UInt64, invalidScope: UInt64) {
        state.withLock { ($0.overflow, $0.invalidScope) }
    }

    func clear() {
        state.withLock { state in
            state.records = []
            state.overflow = 0
            state.invalidScope = 0
        }
    }

    private static func increment(_ value: UInt64) -> UInt64 { value == UInt64.max ? value : value + 1 }
}

nonisolated extension DiagnosticReport {
    static func make(snapshot: DiagnosticSnapshot, directory: URL) -> Self {
        Self(snapshot: snapshot, directory: directory)
    }

    func matches(_ other: Self) -> Bool { token == other.token }
}
