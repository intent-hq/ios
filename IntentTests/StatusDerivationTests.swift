import Testing
@testable import Intent

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
            id: "test", title: "Test", branch: nil, baseRef: nil,
            status: nil, activity: activity, displayStatus: displayStatus,
            attention: attention,
            waiting: waiting,
            lastActivity: nil, updatedAt: nil, repositoryOwner: nil,
            repositoryName: nil, prStatus: prStatus, prNumber: nil,
            diffSummaryTotalFiles: nil,
            taskStatsTotal: nil,
            taskStatsCompleted: nil,
            taskStatsInProgress: nil,
            agentSummaryCount: nil, agentSummaryAgents: nil
        )
    }

    // MARK: - Wire value mapping

    @Test func wireValueMapping() async throws {
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
        #expect(WorkspaceDisplayStatus(wireValue: "pr_merged") == .prMerged)
        #expect(WorkspaceDisplayStatus(wireValue: "some_future_status") == nil)
    }

    // MARK: - Resolution (BE-owned value only)

    @Test func resolveUsesBackendValue() async throws {
        // BE value is authoritative — local workspace fields never override it
        let ws = makeWorkspace(displayStatus: "in_progress", prStatus: "Merged")
        #expect(resolveDisplayStatus(for: ws) == .inProgress)
    }

    @Test func resolveMapsPrReady() async throws {
        let ws = makeWorkspace(displayStatus: "pr_ready", prStatus: "Open")
        #expect(resolveDisplayStatus(for: ws) == .prReady)
    }

    @Test func resolveDefaultsToNotStartedWhenFieldAbsent() async throws {
        let ws = makeWorkspace(prStatus: "Merged")
        #expect(resolveDisplayStatus(for: ws) == .notStarted)
    }

    @Test func resolveMapsUnknownWireValueToUnknown() async throws {
        // A newer daemon's value must not masquerade as .notStarted
        // ("No Code Changes") — it gets its own neutral treatment.
        let ws = makeWorkspace(displayStatus: "some_future_status", prStatus: "Open")
        #expect(resolveDisplayStatus(for: ws) == .unknown)
        #expect(resolveDisplayStatus(for: ws) != .notStarted)
    }

    @Test func resolveMapsIdle() async throws {
        let ws = makeWorkspace(displayStatus: "idle")
        #expect(resolveDisplayStatus(for: ws) == .idle)
    }

    @Test func resolveMapsNeedsAttention() async throws {
        let ws = makeWorkspace(displayStatus: "needs_attention")
        #expect(resolveDisplayStatus(for: ws) == .needsAttention)
    }

    @Test func resolveMapsFailed() async throws {
        let ws = makeWorkspace(displayStatus: "failed", prStatus: "Open")
        #expect(resolveDisplayStatus(for: ws) == .failed)
    }

    @Test func resolveMapsBlocked() async throws {
        let ws = makeWorkspace(displayStatus: "blocked")
        #expect(resolveDisplayStatus(for: ws) == .blocked)
    }

    @Test func resolveMapsLegacyUnreadToIdle() async throws {
        let ws = makeWorkspace(displayStatus: "unread")
        #expect(resolveDisplayStatus(for: ws) == .idle)
    }

    // MARK: - Unread attention flag (blue dot)

    @Test func unreadAttentionFlag() async throws {
        #expect(hasUnreadAttention(makeWorkspace(attention: "unread")))
        #expect(!hasUnreadAttention(makeWorkspace(attention: "none")))
        #expect(!hasUnreadAttention(makeWorkspace(attention: "review_required")))
        #expect(!hasUnreadAttention(makeWorkspace()))
    }

    @Test func unreadAttentionIndependentOfDisplayStatus() async throws {
        // The dot overlays the real status: a complete workspace can be unread.
        let ws = makeWorkspace(displayStatus: "complete", attention: "unread")
        #expect(resolveDisplayStatus(for: ws) == .complete)
        #expect(hasUnreadAttention(ws))
    }

    // MARK: - Waiting flag (grey dot, protocol 6.17)

    @Test func waitingDotShownWhenOnlyWaiting() async throws {
        #expect(showsWaitingDot(makeWorkspace(waiting: true)))
        #expect(!showsWaitingDot(makeWorkspace(waiting: false)))
    }

    @Test func waitingDotYieldsToRunning() async throws {
        // Dot precedence: running > unread > waiting.
        let ws = makeWorkspace(activity: "agent_running", waiting: true)
        #expect(!showsWaitingDot(ws))
    }

    @Test func runningPredicateSharedByGreenAndWaitingDots() async throws {
        // hasRunningAgents is the single predicate behind both the green
        // running dot and the waiting-dot precedence check — they can never
        // disagree on what "running" means (case-insensitive match included).
        #expect(hasRunningAgents(makeWorkspace(activity: "agent_running")))
        #expect(hasRunningAgents(makeWorkspace(activity: "AGENT_RUNNING")))
        #expect(!hasRunningAgents(makeWorkspace(activity: "idle")))
        #expect(!hasRunningAgents(makeWorkspace(activity: nil)))
        #expect(!showsWaitingDot(makeWorkspace(activity: "AGENT_RUNNING", waiting: true)))
    }

    @Test func waitingDotYieldsToUnread() async throws {
        let ws = makeWorkspace(attention: "unread", waiting: true)
        #expect(!showsWaitingDot(ws))
    }

    @Test func waitingDotShownWithNonUnreadAttention() async throws {
        // Only the unread dot outranks waiting; other attention values don't
        // render a dot and must not suppress the waiting affordance.
        #expect(showsWaitingDot(makeWorkspace(attention: "none", waiting: true)))
        #expect(showsWaitingDot(makeWorkspace(attention: "review_required", waiting: true)))
    }

    @Test func waitingOrthogonalToDisplayStatus() async throws {
        // waiting is orthogonal: any status (including in_progress) can wait,
        // and it never changes the resolved display status.
        for wire in ["in_progress", "complete", "pr_ready", "idle"] {
            let ws = makeWorkspace(displayStatus: wire, waiting: true)
            #expect(resolveDisplayStatus(for: ws) == WorkspaceDisplayStatus(wireValue: wire))
            #expect(ws.waiting)
        }
    }

    @Test func waitingNeverFeedsUnreadAttention() async throws {
        // Informational only — no attention/badge escalation from waiting.
        #expect(!hasUnreadAttention(makeWorkspace(waiting: true)))
    }

    // MARK: - Labels

    @Test func statusLabels() async throws {
        #expect(WorkspaceDisplayStatus.failed.label == "Failed")
        #expect(WorkspaceDisplayStatus.blocked.label == "Blocked")
        #expect(WorkspaceDisplayStatus.needsAttention.label == "Needs Attention")
        #expect(WorkspaceDisplayStatus.idle.label == "Idle")
        #expect(WorkspaceDisplayStatus.notStarted.label == "No Code Changes")
        #expect(WorkspaceDisplayStatus.inProgress.label == "In Progress")
        #expect(WorkspaceDisplayStatus.complete.label == "Complete")
        #expect(WorkspaceDisplayStatus.prReady.label == "PR Mergeable")
        #expect(WorkspaceDisplayStatus.prOpen.label == "PR Open")
        #expect(WorkspaceDisplayStatus.prMerged.label == "PR Merged")
        #expect(WorkspaceDisplayStatus.unknown.label == "Unknown")
    }

    // MARK: - Sort order

    @Test func sortOrderOrdering() async throws {
        let ordered: [WorkspaceDisplayStatus] = [
            .failed, .blocked, .needsAttention, .idle, .notStarted,
            .inProgress, .complete, .prOpen, .prReady, .prMerged, .unknown,
        ]
        for i in 0..<ordered.count - 1 {
            #expect(ordered[i].sortOrder < ordered[i + 1].sortOrder)
        }
    }

    @Test func failedSortsFirst() async throws {
        #expect(WorkspaceDisplayStatus.failed.sortOrder == 0)
        for status in WorkspaceDisplayStatus.allCases where status != .failed {
            #expect(WorkspaceDisplayStatus.failed.sortOrder < status.sortOrder)
        }
    }

    @Test func unknownSortsLast() async throws {
        for status in WorkspaceDisplayStatus.allCases where status != .unknown {
            #expect(WorkspaceDisplayStatus.unknown.sortOrder > status.sortOrder)
        }
    }
}

