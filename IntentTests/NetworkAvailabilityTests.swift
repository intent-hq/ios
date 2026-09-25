import Foundation
@testable import Intent
import Network
import Observation
import os
import SwiftUI
import Testing

@MainActor struct NetworkAvailabilityTests {
    @Test func startsUnknownUntilFirstCallbackWithoutASocket() throws {
        let factory = MonitorFactory()
        let availability = NetworkAvailability(makeMonitor: factory.make)
        #expect(availability.status == .unknown)
        #expect(factory.monitors.isEmpty)

        let lease = availability.acquire()
        defer { lease.cancel() }
        let monitor = try #require(factory.monitors.first)
        #expect(monitor.startCount == 1)
        #expect(availability.status == .unknown)
        monitor.report(.requiresConnection)
        #expect(availability.status == .requiresConnection)
    }

    @Test func observesLossAndRecoveryWithoutReplacingMonitor() throws {
        let factory = MonitorFactory()
        let availability = NetworkAvailability(makeMonitor: factory.make)
        let lease = availability.acquire()
        defer { lease.cancel() }
        let monitor = try #require(factory.monitors.first)

        monitor.report(.unsatisfied, reason: .notAvailable)
        #expect(availability.status == .unsatisfied(.notAvailable))
        monitor.report(.requiresConnection, reason: .localNetworkDenied)
        #expect(availability.status == .requiresConnection)
        monitor.report(.satisfied)
        #expect(availability.status == .satisfied)
        monitor.report(.unsatisfied, reason: .localNetworkDenied)
        #expect(availability.status == .unsatisfied(.localNetworkDenied))
        monitor.report(.satisfied)
        #expect(availability.status == .satisfied)
        #expect(factory.monitors.count == 1)
        #expect(monitor.startCount == 1)
        #expect(monitor.cancelCount == 0)
    }

    @Test(arguments: [NWPath.UnsatisfiedReason.notAvailable, .cellularDenied, .wifiDenied, .localNetworkDenied, .vpnInactive])
    func retainsUnsatisfiedReasons(reason: NWPath.UnsatisfiedReason) {
        let snapshot = NetworkPathSnapshot(status: .unsatisfied, interfaces: [], unsatisfiedReason: reason)
        #expect(snapshot.unsatisfiedReason == reason)
        #expect(NetworkAvailability.Status(snapshot) == .unsatisfied(reason))
        #expect(!snapshot.isSatisfied)
    }

    @Test(arguments: [NWPath.Status.satisfied, .requiresConnection])
    func ignoresInapplicableReasons(status: NWPath.Status) {
        let snapshot = NetworkPathSnapshot(status: status, interfaces: [], unsatisfiedReason: .localNetworkDenied)
        #expect(snapshot.unsatisfiedReason == nil)
        #expect(snapshot.isSatisfied == (status == .satisfied))
        #expect(NetworkAvailability.Status(snapshot) == (status == .satisfied ? .satisfied : .requiresConnection))
    }

    @Test(arguments: [false, true]) func legacySnapshotKeepsTransportMeaning(isSatisfied: Bool) {
        let snapshot = NetworkPathSnapshot(isSatisfied: isSatisfied, interfaces: [("radio", .cellular)])
        #expect(snapshot.isSatisfied == isSatisfied)
        #expect(snapshot.status == (isSatisfied ? .satisfied : .unsatisfied))
        #expect(snapshot.unsatisfiedReason == nil)
        #expect(snapshot.physicalInterfaces == ["radio"])
    }

    @Test func repeatedReportsDoNotInvalidateStatusObservers() throws {
        let factory = MonitorFactory()
        let availability = NetworkAvailability(makeMonitor: factory.make)
        let lease = availability.acquire()
        defer { lease.cancel() }
        let monitor = try #require(factory.monitors.first)
        monitor.report(.unsatisfied, reason: .notAvailable)
        let invalidations = OSAllocatedUnfairLock(initialState: 0)
        withObservationTracking {
            _ = availability.status
        } onChange: { @Sendable in
            invalidations.withLock { $0 += 1 }
        }

        monitor.report(.unsatisfied, reason: .notAvailable)
        #expect(invalidations.withLock { $0 } == 0)
        monitor.report(.unsatisfied, reason: .localNetworkDenied)
        #expect(invalidations.withLock { $0 } == 1)
        #expect(availability.status == .unsatisfied(.localNetworkDenied))
    }

    @Test func foregroundWindowsShareMonitorUntilLastLeaseEnds() throws {
        let factory = MonitorFactory()
        let availability = NetworkAvailability(makeMonitor: factory.make)
        let first = availability.acquire()
        let second = availability.acquire()
        let monitor = try #require(factory.monitors.first)
        #expect(factory.monitors.count == 1)
        monitor.report(.satisfied)

        first.cancel()
        first.cancel()
        #expect(monitor.cancelCount == 0)
        #expect(availability.status == .satisfied)
        monitor.report(.unsatisfied)
        #expect(availability.status == .unsatisfied(nil))
        second.cancel()
        second.cancel()
        #expect(monitor.cancelCount == 1)
        #expect(availability.status == .unknown)
    }

    @Test func foregroundRestartUsesFreshMonitorAndRejectsStaleDelivery() async throws {
        let factory = MonitorFactory()
        let availability = NetworkAvailability(makeMonitor: factory.make)
        let first = availability.acquire()
        let retired = try #require(factory.monitors.first)
        let delayedCallback = try #require(retired.onUpdate)
        retired.report(.unsatisfied, reason: .notAvailable)
        first.cancel()
        retired.report(.satisfied)
        #expect(availability.status == .unknown)

        let second = availability.acquire()
        defer { second.cancel() }
        let current = try #require(factory.monitors.last)
        #expect(current !== retired)
        #expect(factory.monitors.count == 2)
        #expect(availability.status == .unknown)
        current.report(.satisfied)
        await Task.detached {
            await delayedCallback(NetworkPathSnapshot(status: .unsatisfied, interfaces: []))
        }.value
        #expect(availability.status == .satisfied)
        #expect(current.cancelCount == 0)
    }

    @Test func cancellationRejectsSynchronousFinalReport() throws {
        let factory = MonitorFactory()
        let availability = NetworkAvailability(makeMonitor: factory.make)
        let lease = availability.acquire()
        let monitor = try #require(factory.monitors.first)
        monitor.reportOnCancel = true
        lease.cancel()
        #expect(availability.status == .unknown)
        #expect(monitor.cancelCount == 1)
    }

    @Test func backgroundDeliveryHopsToMainActor() async throws {
        let factory = MonitorFactory()
        let availability = NetworkAvailability(makeMonitor: factory.make)
        let lease = availability.acquire()
        defer { lease.cancel() }
        let callback = try #require(factory.monitors.first?.onUpdate)
        await Task.detached {
            await callback(NetworkPathSnapshot(status: .requiresConnection, interfaces: []))
        }.value
        #expect(availability.status == .requiresConnection)
    }

    @Test func releasingSceneLeaseCancelsAndDoesNotRetainOwner() throws {
        let factory = MonitorFactory()
        weak var releasedAvailability: NetworkAvailability?
        var lease: NetworkAvailability.Lease?
        do {
            let availability = NetworkAvailability(makeMonitor: factory.make)
            releasedAvailability = availability
            lease = availability.acquire()
        }
        #expect(lease != nil)
        #expect(releasedAvailability != nil)
        let monitor = try #require(factory.monitors.first)
        lease = nil
        #expect(releasedAvailability == nil)
        #expect(monitor.cancelCount == 1)
        monitor.report(.satisfied)
        #expect(releasedAvailability == nil)
    }

    @Test func independentOwnersNeverReuseOneShotMonitor() throws {
        let factory = MonitorFactory()
        let first = NetworkAvailability(makeMonitor: factory.make)
        let second = NetworkAvailability(makeMonitor: factory.make)
        let firstLease = first.acquire()
        let secondLease = second.acquire()
        defer { secondLease.cancel() }
        let firstMonitor = try #require(factory.monitors.first)
        let secondMonitor = try #require(factory.monitors.last)
        #expect(firstMonitor !== secondMonitor)
        firstLease.cancel()
        secondMonitor.report(.satisfied)
        #expect(first.status == .unknown)
        #expect(second.status == .satisfied)
        #expect(secondMonitor.cancelCount == 0)
    }
}

extension NetworkAvailabilityTests {
    @MainActor final class MonitorFactory {
        private(set) var monitors: [FakeMonitor] = []

        func make() -> any NetworkPathMonitoring {
            let monitor = FakeMonitor()
            monitors.append(monitor)
            return monitor
        }
    }

    @MainActor final class FakeMonitor: NetworkPathMonitoring {
        private(set) var startCount = 0
        private(set) var cancelCount = 0
        private(set) var onUpdate: (@MainActor @Sendable (NetworkPathSnapshot) -> Void)?
        var reportOnCancel = false

        func start(onUpdate: @escaping @MainActor @Sendable (NetworkPathSnapshot) -> Void) {
            startCount += 1
            self.onUpdate = onUpdate
        }

        func cancel() {
            cancelCount += 1
            if reportOnCancel { report(.satisfied) }
        }

        func report(_ status: NWPath.Status, reason: NWPath.UnsatisfiedReason? = nil) {
            onUpdate?(NetworkPathSnapshot(status: status, interfaces: [], unsatisfiedReason: reason))
        }
    }
}

#if DEBUG
@MainActor struct NetworkCopyDiagnosticsTests {
    @Test func requiresExactOptInArgumentAndStartsEmpty() throws {
        #expect(NetworkCopyDiagnostics.make(arguments: []) == nil)
        #expect(NetworkCopyDiagnostics.make(arguments: ["--diagnose-network-copy=false"]) == nil)
        let diagnostics = try #require(NetworkCopyDiagnostics.make(arguments: ["--diagnose-network-copy"]))
        #expect(diagnostics.entries.isEmpty)
        #expect(diagnostics.readout.isEmpty)
    }

    @Test func schemaOnlyRendersAllowlistedFields() {
        typealias Event = NetworkCopyDiagnostics.Event
        let statuses: [(NetworkAvailability.Status, String)] = [
            (.unknown, "unknown reason=none"),
            (.satisfied, "satisfied reason=none"),
            (.requiresConnection, "requiresConnection reason=none"),
            (.unsatisfied(nil), "unsatisfied reason=none"),
            (.unsatisfied(.notAvailable), "unsatisfied reason=notAvailable"),
            (.unsatisfied(.cellularDenied), "unsatisfied reason=cellularDenied"),
            (.unsatisfied(.wifiDenied), "unsatisfied reason=wifiDenied"),
            (.unsatisfied(.localNetworkDenied), "unsatisfied reason=localNetworkDenied"),
            (.unsatisfied(.vpnInactive), "unsatisfied reason=vpnInactive")
        ]
        for (status, fields) in statuses {
            #expect(Event.monitor(status, accepted: true).line == "monitor status=\(fields) delivery=accepted")
            #expect(Event.monitor(status, accepted: false).line == "monitor status=\(fields) delivery=stale")
            let offline = ConnectionNetworkMessage(status: status).isUnavailable
            #expect(Event.presenter(status, offline: offline, presented: true).line
                == "presenter status=\(fields) copy=\(offline ? "offline" : "reconnecting") visible=true")
        }
        #expect(Event.scene(.init(.active), lease: true).line == "scene=active lease=true")
        #expect(Event.scene(.init(.inactive), lease: true).line == "scene=inactive lease=true")
        #expect(Event.scene(.init(.background), lease: false).line == "scene=background lease=false")
        #expect(Event.scene(.stopped, lease: false).line == "scene=stopped lease=false")
    }

    @Test func historyIsBoundedAndDuplicateEventsDoNotAdvanceSequence() throws {
        let diagnostics = try #require(NetworkCopyDiagnostics.make(arguments: ["--diagnose-network-copy"]))
        let count = NetworkCopyDiagnostics.maximumEntries + 3
        for index in 1...count {
            let event = NetworkCopyDiagnostics.Event.scene(.active, lease: index.isMultiple(of: 2))
            diagnostics.record(event)
            diagnostics.record(event)
        }
        #expect(diagnostics.entries.count == NetworkCopyDiagnostics.maximumEntries)
        #expect(diagnostics.entries.first?.sequence == 4)
        #expect(diagnostics.entries.last?.sequence == count)
        #expect(diagnostics.readout.split(separator: "\n").count == NetworkCopyDiagnostics.maximumEntries)
    }

    @Test func recordingDoesNotSubscribePresenterToDiagnostics() throws {
        let diagnostics = try #require(NetworkCopyDiagnostics.make(arguments: ["--diagnose-network-copy"]))
        let invalidations = OSAllocatedUnfairLock(initialState: 0)
        withObservationTracking {
            diagnostics.record(.presenter(.unknown, offline: false, presented: true))
        } onChange: { @Sendable in
            invalidations.withLock { $0 += 1 }
        }
        diagnostics.record(.monitor(.unsatisfied(.notAvailable), accepted: true))
        #expect(invalidations.withLock { $0 } == 0)
    }
}
#endif
