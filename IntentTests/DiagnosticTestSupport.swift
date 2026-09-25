import Foundation
@testable import Intent
import Synchronization

nonisolated final class DiagnosticTestClock: Sendable {
    private static let epoch: TimeInterval = 1_800_000_000

    private struct State {
        var date: Date
        var reads = 0
    }

    private let value = Mutex(State(date: Date(timeIntervalSince1970: epoch)))

    var readCount: Int { value.withLock { $0.reads } }

    func now() -> Date {
        value.withLock { state in
            state.reads += 1
            return state.date
        }
    }

    func advance(_ seconds: TimeInterval) { value.withLock { $0.date.addTimeInterval(seconds) } }
}

nonisolated final class DiagnosticTestStorage: DiagnosticStorage, Sendable {
    struct State {
        var failRead = false
        var failWrite = false
        var failClear = false
        var touchedMainThread = false
        var writes = 0
        var afterReportWrite: (@Sendable () throws -> Void)?
    }

    enum Failure: Error { case simulated }

    let state = Mutex(State())
    let files: DiagnosticFileStorage

    init() {
        files = DiagnosticFileStorage(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("DiagnosticTests-\(UUID().uuidString)", isDirectory: true))
    }

    deinit { try? FileManager.default.removeItem(at: files.directory) }

    func prepare() throws {
        observeThread()
        try files.prepare()
    }

    func readHistory(maximumBytes: Int) throws -> Data {
        observeThread()
        if state.withLock({ $0.failRead }) { throw Failure.simulated }
        return try files.readHistory(maximumBytes: maximumBytes)
    }

    func replaceHistory(_ data: Data) throws {
        observeThread()
        let fail = state.withLock { state in
            state.writes += 1
            return state.failWrite
        }
        if fail { throw Failure.simulated }
        try files.replaceHistory(data)
    }

    func clearHistory() throws {
        observeThread()
        if state.withLock({ $0.failClear }) { throw Failure.simulated }
        try files.clearHistory()
    }

    func clearReports() throws {
        observeThread()
        if state.withLock({ $0.failClear }) { throw Failure.simulated }
        try files.clearReports()
    }

    func prepareReport(snapshot: DiagnosticSnapshot) throws -> URL {
        observeThread()
        if state.withLock({ $0.failWrite }) { throw Failure.simulated }
        let directory = try files.prepareReport(snapshot: snapshot)
        let afterReportWrite = state.withLock { $0.afterReportWrite }
        try afterReportWrite?()
        return directory
    }

    private func observeThread() {
        state.withLock { $0.touchedMainThread = $0.touchedMainThread || Thread.isMainThread }
    }
}

nonisolated enum DiagnosticFixtures {
    static func event(
        operation: DiagnosticOperation = .workspaceLoad,
        stage: DiagnosticEvent.Stage = .request,
        outcome: DiagnosticEvent.Outcome = .failed,
        failure: DiagnosticFailure = DiagnosticFailure(origin: .localRequest, classification: .requestTimeout)
    ) -> DiagnosticEvent {
        DiagnosticEvent(
            kind: .operationFailed,
            operation: operation,
            site: .workspaceStore,
            stage: stage,
            outcome: outcome,
            failure: failure
        )
    }

    static func records(_ snapshot: DiagnosticSnapshot) throws -> [DiagnosticRecord] {
        try snapshot.jsonLines.split(separator: DiagnosticEncoding.newline).map { line in
            try DiagnosticEncoding.decoder().decode(DiagnosticRecord.self, from: Data(line))
        }
    }
}
