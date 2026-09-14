@testable import Intent
import Testing

struct StatusDerivationTests {
    // Helper to build a Workspace with specific fields. Only `displayStatus`
    // feeds the resolution; `prStatus` is kept to pin that BE authority is not
    // overridden by the parallel PR surface.
    private func makeWorkspace(
        displayStatus: String? = nil,
        attention: String? = nil,
        prStatus: String? = nil,
        activity: String? = nil,
        waiting: Bool = false
    ) -> Workspace {
        Workspace(
            id: "test",
            title: "Test",
            branch: nil,
            baseRef: nil,
            status: nil,
            activity: activity,
            displayStatus: displayStatus,
            attention: attention,
            waiting: waiting,
            lastActivity: nil,
            updatedAt: nil,
            repositoryOwner: nil,
            repositoryName: nil,
            prStatus: prStatus,
            prNumber: nil,
            diffSummaryTotalFiles: nil,
            taskStatsTotal: nil,
            taskStatsCompleted: nil,
            taskStatsInProgress: nil,
            agentSummaryCount: nil,
            agentSummaryAgents: nil
        )
    }

    // MARK: - Wire value mapping

    @Test func wireValueMapping() async {
        #expect(WorkspaceDisplayStatus(wireValue: "failed") == .failed)
        #expect(WorkspaceDisplayStatus(wireValue: "blocked") == .blocked)
        #expect(WorkspaceDisplayStatus(wireValue: "needs_attention") == .needsAttention)
        #expect(WorkspaceDisplayStatus(wireValue: "idle") == .idle)
        #expect(WorkspaceDisplayStatus(wireValue: "not_started") == .notStarted)
        #expect(WorkspaceDisplayStatus(wireValue: "in_progress") == .inProgress)
        // Legacy wire value from older daemons — unread is now the
        // attention-flag dot, so the status folds into .idle.
        #expect(WorkspaceDisplayStatus(wireValue: "unread") == .idle)
        #expect(WorkspaceDisplayStatus(wireValue: "complete") == .complete)
        #expect(WorkspaceDisplayStatus(wireValue: "pr_ready") == .prReady)
        #expect(WorkspaceDisplayStatus(wireValue: "pr_open") == .prOpen)
        #expect(WorkspaceDisplayStatus(wireValue: "pr_queued") == .prQueued)
        #expect(WorkspaceDisplayStatus(wireValue: "pr_merged") == .prMerged)
        #expect(WorkspaceDisplayStatus(wireValue: "some_future_status") == nil)
    }

    // MARK: - Resolution (BE-owned value only)

    @Test func resolveUsesBackendValue() async {
        // BE value is authoritative — local workspace fields never override it
        let workspace = makeWorkspace(displayStatus: "in_progress", prStatus: "Merged")
        #expect(resolveDisplayStatus(for: workspace) == .inProgress)
    }

    @Test func resolveMapsPrReady() async {
        let workspace = makeWorkspace(displayStatus: "pr_ready", prStatus: "Open")
        #expect(resolveDisplayStatus(for: workspace) == .prReady)
    }

    @Test func resolveMapsPrQueued() async {
        let workspace = makeWorkspace(displayStatus: "pr_queued", prStatus: "Open")
        #expect(resolveDisplayStatus(for: workspace) == .prQueued)
    }

    @Test func resolveDefaultsToNotStartedWhenFieldAbsent() async {
        let workspace = makeWorkspace(prStatus: "Merged")
        #expect(resolveDisplayStatus(for: workspace) == .notStarted)
    }

    @Test func resolveMapsUnknownWireValueToUnknown() async {
        // A newer daemon's value must not masquerade as .notStarted
        // ("No Code Changes") — it gets its own neutral treatment.
        let workspace = makeWorkspace(displayStatus: "some_future_status", prStatus: "Open")
        #expect(resolveDisplayStatus(for: workspace) == .unknown)
        #expect(resolveDisplayStatus(for: workspace) != .notStarted)
    }

    @Test func resolveMapsIdle() async {
        let workspace = makeWorkspace(displayStatus: "idle")
        #expect(resolveDisplayStatus(for: workspace) == .idle)
    }

    @Test func resolveMapsNeedsAttention() async {
        let workspace = makeWorkspace(displayStatus: "needs_attention")
        #expect(resolveDisplayStatus(for: workspace) == .needsAttention)
    }

    @Test func resolveMapsFailed() async {
        let workspace = makeWorkspace(displayStatus: "failed", prStatus: "Open")
        #expect(resolveDisplayStatus(for: workspace) == .failed)
    }

    @Test func resolveMapsBlocked() async {
        let workspace = makeWorkspace(displayStatus: "blocked")
        #expect(resolveDisplayStatus(for: workspace) == .blocked)
    }

    @Test func resolveMapsLegacyUnreadToIdle() async {
        let workspace = makeWorkspace(displayStatus: "unread")
        #expect(resolveDisplayStatus(for: workspace) == .idle)
    }

    // MARK: - Unread attention flag (blue dot)

    @Test func unreadAttentionFlag() async {
        #expect(hasUnreadAttention(makeWorkspace(attention: "unread")))
        #expect(!hasUnreadAttention(makeWorkspace(attention: "none")))
        #expect(!hasUnreadAttention(makeWorkspace(attention: "review_required")))
        #expect(!hasUnreadAttention(makeWorkspace()))
    }

    @Test func unreadAttentionIndependentOfDisplayStatus() async {
        // The dot overlays the real status: a complete workspace can be unread.
        let workspace = makeWorkspace(displayStatus: "complete", attention: "unread")
        #expect(resolveDisplayStatus(for: workspace) == .complete)
        #expect(hasUnreadAttention(workspace))
    }

    // MARK: - Waiting flag (grey dot, protocol 6.17)

    @Test func waitingDotShownWhenOnlyWaiting() async {
        #expect(showsWaitingDot(makeWorkspace(waiting: true)))
        #expect(!showsWaitingDot(makeWorkspace(waiting: false)))
    }

    @Test func waitingDotYieldsToRunning() async {
        // Dot precedence: running > unread > waiting.
        let workspace = makeWorkspace(activity: "agent_running", waiting: true)
        #expect(!showsWaitingDot(workspace))
    }

    @Test func runningPredicateSharedByGreenAndWaitingDots() async {
        // hasRunningAgents is the single predicate behind both the green
        // running dot and the waiting-dot precedence check — they can never
        // disagree on what "running" means (case-insensitive match included).
        #expect(hasRunningAgents(makeWorkspace(activity: "agent_running")))
        #expect(hasRunningAgents(makeWorkspace(activity: "AGENT_RUNNING")))
        #expect(!hasRunningAgents(makeWorkspace(activity: "idle")))
        #expect(!hasRunningAgents(makeWorkspace(activity: nil)))
        #expect(!showsWaitingDot(makeWorkspace(activity: "AGENT_RUNNING", waiting: true)))
    }

    @Test func waitingDotYieldsToUnread() async {
        let workspace = makeWorkspace(attention: "unread", waiting: true)
        #expect(!showsWaitingDot(workspace))
    }

    @Test func waitingDotShownWithNonUnreadAttention() async {
        // Only the unread dot outranks waiting; other attention values don't
        // render a dot and must not suppress the waiting affordance.
        #expect(showsWaitingDot(makeWorkspace(attention: "none", waiting: true)))
        #expect(showsWaitingDot(makeWorkspace(attention: "review_required", waiting: true)))
    }

    @Test func waitingOrthogonalToDisplayStatus() async {
        // waiting is orthogonal: any status (including in_progress) can wait,
        // and it never changes the resolved display status.
        for wire in ["in_progress", "complete", "pr_ready", "idle"] {
            let workspace = makeWorkspace(displayStatus: wire, waiting: true)
            #expect(resolveDisplayStatus(for: workspace) == WorkspaceDisplayStatus(wireValue: wire))
            #expect(workspace.waiting)
        }
    }

    @Test func waitingNeverFeedsUnreadAttention() async {
        // Informational only — no attention/badge escalation from waiting.
        #expect(!hasUnreadAttention(makeWorkspace(waiting: true)))
    }

    // MARK: - Labels

    @Test func statusLabels() async {
        #expect(WorkspaceDisplayStatus.failed.label == "Failed")
        #expect(WorkspaceDisplayStatus.blocked.label == "Blocked")
        #expect(WorkspaceDisplayStatus.needsAttention.label == "Needs Attention")
        #expect(WorkspaceDisplayStatus.idle.label == "Idle")
        #expect(WorkspaceDisplayStatus.notStarted.label == "No Code Changes")
        #expect(WorkspaceDisplayStatus.inProgress.label == "In Progress")
        #expect(WorkspaceDisplayStatus.complete.label == "Complete")
        #expect(WorkspaceDisplayStatus.prReady.label == "PR Mergeable")
        #expect(WorkspaceDisplayStatus.prOpen.label == "PR Open")
        #expect(WorkspaceDisplayStatus.prQueued.label == "PR Queued")
        #expect(WorkspaceDisplayStatus.prMerged.label == "PR Merged")
        #expect(WorkspaceDisplayStatus.unknown.label == "Unknown")
    }

    // MARK: - Sort order

    @Test func sortOrderOrdering() async {
        let ordered: [WorkspaceDisplayStatus] = [
            .failed,
            .blocked,
            .needsAttention,
            .idle,
            .notStarted,
            .inProgress,
            .complete,
            .prOpen,
            .prReady,
            .prQueued,
            .prMerged,
            .unknown
        ]
        for i in 0..<ordered.count - 1 {
            #expect(ordered[i].sortOrder < ordered[i + 1].sortOrder)
        }
    }

    @Test func failedSortsFirst() async {
        #expect(WorkspaceDisplayStatus.failed.sortOrder == 0)
        for status in WorkspaceDisplayStatus.allCases where status != .failed {
            #expect(WorkspaceDisplayStatus.failed.sortOrder < status.sortOrder)
        }
    }

    @Test func unknownSortsLast() async {
        for status in WorkspaceDisplayStatus.allCases where status != .unknown {
            #expect(WorkspaceDisplayStatus.unknown.sortOrder > status.sortOrder)
        }
    }
}
