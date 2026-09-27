import Foundation
@testable import Intent
import SwiftUI
import Testing
import UIKit

/// Display-helper and hosted accessibility tests for the monitored-PRs chip row.
@MainActor
struct MonitoredPrsRowTests {
    private static let hostWidth: CGFloat = 600
    private static let hostHeight: CGFloat = 80
    private static let accessibilityObservationDeadline: TimeInterval = 3
    private static let accessibilityObservationInterval: TimeInterval = 0.02

    private func makeMonitor(
        monitorId: String = "prm-1",
        repo: String = "octo/repo",
        prNumber: Int = 12,
        title: String? = "Add review wire surface",
        url: String? = "https://github.com/octo/repo/pull/12",
        pendingChanges: [String] = [],
        hasPendingChanges: Bool = false,
        lastChangeAt: String? = nil,
        snapshot: MonitoredPr.Snapshot? = nil
    ) -> MonitoredPr {
        MonitoredPr(
            monitorId: monitorId,
            workspaceId: "ws-abc",
            agentId: "agent-1",
            repo: repo,
            prNumber: prNumber,
            state: .active,
            pendingChanges: pendingChanges,
            hasPendingChanges: hasPendingChanges,
            createdAt: nil,
            updatedAt: nil,
            pendingSince: nil,
            lastChangeAt: lastChangeAt,
            lastPolledAt: nil,
            lastError: nil,
            title: title,
            url: url,
            lastSnapshot: snapshot
        )
    }
}

extension MonitoredPrsRowTests {
    @Test func accessibilityTraversalReachesChipsInsideNonViewScrollContainers() {
        let host = UIView()
        let scrollContainer = NSObject()
        let chip = UIAccessibilityElement(accessibilityContainer: scrollContainer)
        chip.accessibilityIdentifier = "monitoredPr.nested"
        chip.accessibilityLabel = "#12"
        chip.accessibilityValue = "Pending changes"
        chip.accessibilityTraits = .button
        scrollContainer.accessibilityElements = [chip]
        host.accessibilityElements = [scrollContainer]
        let elements = SyntheticBadgeHost.accessibilityElements(in: host)
        #expect(elements.contains { $0 === chip })
        #expect(elements.first { $0 === chip }?.accessibilityTraits.contains(.button) == true)
    }

    @Test func accessibilityTraversalDeduplicatesContainersAndStopsCycles() {
        let host = UIView()
        let container = NSObject()
        let chip = UIAccessibilityElement(accessibilityContainer: container)
        chip.accessibilityIdentifier = "monitoredPr.once"
        host.accessibilityElements = [container, chip]
        container.accessibilityElements = [host, chip]
        defer { container.accessibilityElements = nil; host.accessibilityElements = nil }
        #expect(SyntheticBadgeHost.accessibilityElements(in: host).filter { $0 === chip }.count == 1)
    }

    private func makeRow(monitors: [MonitoredPr]) -> some View {
        let connection = FakeConnectionManager()
        let workspaceStore = WorkspaceStore(forTesting: true)
        workspaceStore.workspaces = [
            Workspace(
                id: "ws-abc",
                title: "Test",
                branch: nil,
                baseRef: nil,
                status: nil,
                activity: nil,
                displayStatus: nil,
                repositoryOwner: "octo",
                repositoryName: "repo"
            )
        ]
        let viewModel = ConversationViewModel(
            agentId: "agent-1",
            workspaceId: "ws-abc",
            agentName: "Test",
            connection: connection,
            uploadService: AttachmentUploadService(connection: connection),
            optionsStore: CreationOptionsStore(connectionManager: connection)
        )
        let monitoredPrStore = MonitoredPrStore(connectionManager: connection)
        monitoredPrStore.activate(workspaceId: "ws-abc")
        monitoredPrStore.source.cache.buckets["ws-abc"]?.rows = monitors
        let session = makeSession(connection: connection, workspaceStore: workspaceStore)
        return MonitoredPrsRow(viewModel: viewModel, monitoredPrStore: monitoredPrStore)
            .environment(session)
    }

    private func makeSession(
        connection: FakeConnectionManager,
        workspaceStore: WorkspaceStore
    ) -> BackendSession {
        let fileLoader = WorkspaceFileImageLoader(connection: connection)
        return BackendSession(
            backendID: BackendID(UUID()),
            connection: connection,
            workspaceStore: workspaceStore,
            coordinatorFactory: { _ in fatalError("coordinator is not built in these tests") },
            githubRepoStore: GitHubRepoStore(connectionManager: connection),
            creationOptionsStore: CreationOptionsStore(connectionManager: connection),
            prMonitorsStore: WorkspacePrMonitorsStore(connectionManager: connection),
            attachmentUploadService: AttachmentUploadService(connection: connection),
            workspaceFileImageLoader: fileLoader,
            attachmentImageLoader: AttachmentImageLoader(
                connection: connection,
                fileLoader: fileLoader
            ),
            attentionCueCenter: WorkspaceAttentionCueCenter {}
        )
    }

    private static func accessibilityElements(
        identifiedBy identifiers: [String],
        in hostView: UIView
    ) throws -> [NSObject] {
        let deadline = Date(timeIntervalSinceNow: accessibilityObservationDeadline)
        var elements: [NSObject] = []
        while Date() < deadline {
            let renderedElements = SyntheticBadgeHost.accessibilityElements(in: hostView)
            elements = identifiers.compactMap { identifier in
                renderedElements.first { element in
                    SyntheticBadgeHost.accessibilityIdentifier(of: element) == identifier
                }
            }
            if elements.count == identifiers.count { return elements }
            _ = RunLoop.current.run(
                mode: .default,
                before: Date(timeIntervalSinceNow: accessibilityObservationInterval)
            )
            hostView.layoutIfNeeded()
        }
        let renderedIdentifiers = SyntheticBadgeHost.accessibilityElements(in: hostView)
            .compactMap(SyntheticBadgeHost.accessibilityIdentifier(of:))
        throw ConditionWaitFailure(
            description: "Timed out waiting for \(identifiers); rendered \(renderedIdentifiers)"
        )
    }

    @Test(
        .enabled(
            Comment(
                rawValue:
                    "SwiftUI publishes its accessibility tree only when accessibility is enabled "
                    + "for the process (scripts/xcodebuild.sh enables it on the simulator)"
            )
        ) {
            await SyntheticBadgeHost.publishesAccessibilityTree()
        }
    )
    func renderedChipsExposePendingStateAndPreserveMenuRole() async throws {
        let row = makeRow(monitors: [
            makeMonitor(
                monitorId: "prm-pending",
                pendingChanges: ["checks changed"],
                hasPendingChanges: true
            ),
            makeMonitor(
                monitorId: "prm-pending-without-details",
                prNumber: 23,
                hasPendingChanges: true
            ),
            makeMonitor(monitorId: "prm-current", repo: "other/repo", prNumber: 34)
        ])
        let identifiers = [
            "monitoredPr.prm-pending",
            "monitoredPr.prm-pending-without-details",
            "monitoredPr.prm-current"
        ]

        try await SyntheticBadgeHost.render(
            row,
            width: Self.hostWidth,
            height: Self.hostHeight
        ) { hostView, _ in
            let elements = try Self.accessibilityElements(
                identifiedBy: identifiers,
                in: hostView
            )
            #expect(elements.map(\.accessibilityLabel) == ["#12", "#23", "other/repo: #34"])
            #expect(
                elements.map(\.accessibilityValue)
                    == ["1 pending change", "Pending changes", "No pending changes"]
            )
            #expect(elements.allSatisfy { $0.accessibilityTraits.contains(.button) })
        }
    }

    private func makeSnapshot(
        mergeability: MergeabilityState = .computing,
        mergeBlockedReason: String? = nil,
        checks: MonitoredPr.Snapshot.Checks = .init(total: 0, passed: 0, failed: 0, pending: 0),
        approvals: MonitoredPr.Snapshot.Approvals = .init(decision: "none", have: 0, needed: nil, changesRequested: 0),
        threads: MonitoredPr.Snapshot.Threads = .init(unresolved: 0)
    ) -> MonitoredPr.Snapshot {
        MonitoredPr.Snapshot(
            state: "open",
            isDraft: false,
            hasConflicts: false,
            isBehind: false,
            mergeability: mergeability,
            mergeBlockedReason: mergeBlockedReason,
            checks: checks,
            approvals: approvals,
            threads: threads
        )
    }

    // MARK: - Chip label

    @Test func chipLabelSameRepoIsBareNumber() {
        let monitor = makeMonitor()
        #expect(MonitoredPrsRow.chipLabel(monitor, workspaceRepo: "octo/repo") == "#12")
    }

    @Test func chipLabelCrossRepoIsPrefixed() {
        let monitor = makeMonitor(repo: "other/repo")
        #expect(MonitoredPrsRow.chipLabel(monitor, workspaceRepo: "octo/repo") == "other/repo: #12")
    }

    @Test func chipLabelUnknownWorkspaceRepoFallsBackToBareNumber() {
        let monitor = makeMonitor(repo: "other/repo")
        #expect(MonitoredPrsRow.chipLabel(monitor, workspaceRepo: nil) == "#12")
    }

    // MARK: - PR URL

    @Test func prUrlPrefersWireUrl() {
        let monitor = makeMonitor(url: "https://example.com/pr/12")
        #expect(MonitoredPrsRow.prUrl(monitor) == "https://example.com/pr/12")
    }

    @Test func prUrlFallsBackToCanonicalGithubForm() {
        let monitor = makeMonitor(url: nil)
        #expect(MonitoredPrsRow.prUrl(monitor) == "https://github.com/octo/repo/pull/12")
    }

    // MARK: - Checks summary

    @Test func checksSummaryNilWithoutSnapshotOrChecks() {
        #expect(MonitoredPrsRow.checksSummary(makeMonitor()) == nil)
        let empty = makeMonitor(snapshot: makeSnapshot())
        #expect(MonitoredPrsRow.checksSummary(empty) == nil)
    }

    @Test func checksSummaryPrefersFailingThenPendingThenPassing() {
        let failing = makeMonitor(snapshot: makeSnapshot(
            checks: .init(total: 4, passed: 2, failed: 1, pending: 1)
        ))
        #expect(MonitoredPrsRow.checksSummary(failing) == "1/4 failing")
        let pending = makeMonitor(snapshot: makeSnapshot(
            checks: .init(total: 4, passed: 2, failed: 0, pending: 2)
        ))
        #expect(MonitoredPrsRow.checksSummary(pending) == "2/4 pending")
        let passing = makeMonitor(snapshot: makeSnapshot(
            checks: .init(total: 4, passed: 4, failed: 0, pending: 0)
        ))
        #expect(MonitoredPrsRow.checksSummary(passing) == "4/4 passing")
    }

    // MARK: - Approvals / threads summaries

    @Test func approvalsSummaryIncludesNeededWhenKnown() {
        let known = makeMonitor(snapshot: makeSnapshot(
            approvals: .init(decision: "approved", have: 1, needed: 2, changesRequested: 0)
        ))
        #expect(MonitoredPrsRow.approvalsSummary(known) == "approved (1/2 approvals)")
        let unknown = makeMonitor(snapshot: makeSnapshot(
            approvals: .init(decision: "approved", have: 2, needed: nil, changesRequested: 0)
        ))
        #expect(MonitoredPrsRow.approvalsSummary(unknown) == "approved (2 approvals)")
        #expect(MonitoredPrsRow.approvalsSummary(makeMonitor()) == nil)
    }

    @Test func approvalsSummarySingularizesOneApproval() {
        let neededOne = makeMonitor(snapshot: makeSnapshot(
            approvals: .init(decision: "approved", have: 1, needed: 1, changesRequested: 0)
        ))
        #expect(MonitoredPrsRow.approvalsSummary(neededOne) == "approved (1/1 approval)")
        let haveOne = makeMonitor(snapshot: makeSnapshot(
            approvals: .init(decision: "approved", have: 1, needed: nil, changesRequested: 0)
        ))
        #expect(MonitoredPrsRow.approvalsSummary(haveOne) == "approved (1 approval)")
    }

    @Test func threadsSummaryPluralizesAndHidesZero() {
        let none = makeMonitor(snapshot: makeSnapshot(threads: .init(unresolved: 0)))
        #expect(MonitoredPrsRow.threadsSummary(none) == nil)
        let one = makeMonitor(snapshot: makeSnapshot(threads: .init(unresolved: 1)))
        #expect(MonitoredPrsRow.threadsSummary(one) == "1 unresolved thread")
        let many = makeMonitor(snapshot: makeSnapshot(threads: .init(unresolved: 3)))
        #expect(MonitoredPrsRow.threadsSummary(many) == "3 unresolved threads")
    }

    // MARK: - Pending / detail lines

    @Test func pendingSummaryPluralizes() {
        #expect(MonitoredPrsRow.pendingSummary(makeMonitor()) == "No pending changes")
        #expect(MonitoredPrsRow.pendingSummary(makeMonitor(hasPendingChanges: true))
            == "Pending changes")
        #expect(MonitoredPrsRow.pendingSummary(makeMonitor(
            pendingChanges: ["a"],
            hasPendingChanges: true
        ))
            == "1 pending change")
        #expect(MonitoredPrsRow.pendingSummary(makeMonitor(
            pendingChanges: ["a", "b"],
            hasPendingChanges: true
        ))
            == "2 pending changes")
    }

    @Test func detailLinesWithFullSnapshot() {
        let monitor = makeMonitor(
            pendingChanges: ["check ci: pending → failed"],
            hasPendingChanges: true,
            snapshot: makeSnapshot(
                checks: .init(total: 3, passed: 2, failed: 1, pending: 0),
                approvals: .init(decision: "approved", have: 1, needed: 1, changesRequested: 0),
                threads: .init(unresolved: 2)
            )
        )
        let lines = MonitoredPrsRow.detailLines(monitor)
        #expect(lines == [
            "Add review wire surface — open",
            "octo/repo#12 · 1/3 failing · approved (1/1 approval) · 2 unresolved threads",
            "1 pending change"
        ])
    }

    @Test func detailLinesDropDuplicateSummaryWithoutTitleOrSnapshot() {
        // The no-title/no-snapshot fallback would render the summary line
        // identical to the title line — it is dropped so lines stay distinct.
        let monitor = makeMonitor(title: nil)
        let lines = MonitoredPrsRow.detailLines(monitor)
        #expect(lines == ["octo/repo#12", "No pending changes"])
    }

    // MARK: - Merge summary / last change

    @Test func mergeSummaryPrefersBlockedReasonOverMergeable() {
        #expect(MonitoredPrsRow.mergeSummary(makeMonitor()) == nil)
        let unknown = makeMonitor(snapshot: makeSnapshot())
        #expect(MonitoredPrsRow.mergeSummary(unknown) == nil)
        let blocked = makeMonitor(snapshot: makeSnapshot(
            mergeability: .mergeable,
            mergeBlockedReason: "2 failing checks"
        ))
        #expect(MonitoredPrsRow.mergeSummary(blocked) == "Merge blocked: 2 failing checks")
        let mergeable = makeMonitor(snapshot: makeSnapshot(mergeability: .mergeable))
        #expect(MonitoredPrsRow.mergeSummary(mergeable) == "Mergeable")
        let notMergeable = makeMonitor(snapshot: makeSnapshot(mergeability: .notMergeable))
        #expect(MonitoredPrsRow.mergeSummary(notMergeable) == "Not mergeable")
    }

    @Test func detailLinesIncludeMergeAndLastChangeLines() throws {
        let monitor = makeMonitor(
            lastChangeAt: "2026-07-31T10:00:00Z",
            snapshot: makeSnapshot(mergeability: .notMergeable)
        )
        let now = try #require(ISO8601DateFormatter.lenientDate(from: "2026-07-31T10:05:30Z"))
        #expect(MonitoredPrsRow.detailLines(monitor, now: now) == [
            "Add review wire surface — open",
            "octo/repo#12 · none (0 approvals)",
            "Not mergeable",
            "Last change 5m 30s ago",
            "No pending changes"
        ])
    }
}
