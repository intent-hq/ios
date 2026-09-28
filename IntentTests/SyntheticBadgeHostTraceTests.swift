import Foundation
import Testing

@MainActor
struct SyntheticBadgeHostTraceTests {
    @Test func tracePreservesEventOrderTimeAndSnapshotValues() throws {
        var time: TimeInterval = 100
        var hidden = true
        let trace = SyntheticBadgeHostTrace(context: "agent/large") { time }
        trace.captureState = { ["hidden": String(hidden)] }
        trace.record("wait.install", fields: ["event": "didAppear"])
        time += 1
        hidden = false
        trace.record("show.return")

        let report = try JSONDecoder().decode(SyntheticBadgeHostTrace.Report.self, from: trace.encodedReport())
        #expect(report.context == "agent/large")
        #expect(report.entries.map(\.event) == ["wait.install", "show.return"])
        #expect(report.entries.map(\.elapsed) == [0, 1])
        #expect(report.entries.map { $0.state["hidden"] } == ["true", "false"])
        #expect(report.entries[0].fields["event"] == "didAppear")
        #expect(report.omittedEntries == 0)
        #expect(report.startedAt > 0)
    }

    @Test func boundedTraceKeepsInitialEvidenceAndLatestCleanup() {
        let trace = SyntheticBadgeHostTrace(context: "bounded")
        trace.record("wait.install")
        for _ in 0..<SyntheticBadgeHostTrace.capacity {
            trace.record("callback")
        }
        trace.record("cleanup.finished")

        #expect(trace.entries.count == SyntheticBadgeHostTrace.capacity)
        #expect(trace.entries.first?.event == "wait.install")
        #expect(trace.entries.last?.event == "cleanup.finished")
        #expect(trace.omittedEntries == 2)
    }

    @Test func separateRendersHaveIndependentIdentityAndHistory() {
        let first = SyntheticBadgeHostTrace(context: "first")
        let second = SyntheticBadgeHostTrace(context: "second")
        first.record("wait.install")
        second.record("cleanup.finished")

        #expect(first.id != second.id)
        #expect(first.entries.map(\.event) == ["wait.install"])
        #expect(second.entries.map(\.event) == ["cleanup.finished"])
    }

    @Test func traceReadsStateOnlyAtRecordedBoundaries() throws {
        var reads = 0
        let trace = SyntheticBadgeHostTrace(context: "passive")
        trace.captureState = {
            reads += 1
            return ["read": String(reads)]
        }
        #expect(reads == 0)
        trace.record("boundary")
        #expect(reads == 1)
        _ = try trace.encodedReport()
        trace.publish()
        #expect(reads == 1)
    }
}
