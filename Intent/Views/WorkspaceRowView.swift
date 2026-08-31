import SwiftUI

struct WorkspaceRowView: View {
    let workspace: Workspace
    let colorScheme: ColorScheme
    var showRepo: Bool = true
    /// Workspace-scoped PR monitors feeding the pill pool and the "+N"
    /// indicator; the owning list provides the shared store.
    private let monitorsSource = WorkspacePrMonitorsStore.shared

    private var displayStatus: WorkspaceDisplayStatus {
        resolveDisplayStatus(for: workspace)
    }

    private var prIndicator: PrIndicatorModel {
        Self.derivePrIndicator(
            workspace: workspace,
            monitors: monitorsSource.monitors(for: workspace.id))
    }

    private var hasActiveAgents: Bool {
        hasRunningAgents(workspace)
    }

    var body: some View {
        HStack(spacing: 12) {
            // Status icon with agent activity / unread dot overlays
            ZStack(alignment: .topTrailing) {
                statusIcon

                if hasActiveAgents {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 5, height: 5)
                        .offset(x: 2, y: -2)
                }

                // Blue dot: server-owned unread attention flag, overlaying the
                // real status; cleared via workspace.markSeen on open.
                if hasUnreadAttention(workspace) {
                    Circle()
                        .fill(workspaceUnreadColor)
                        .frame(width: 5, height: 5)
                        .offset(x: 2, y: hasActiveAgents ? 5 : -2)
                }

                // Grey static dot: orthogonal waiting flag (protocol 6.17).
                // Lowest precedence — running and unread dots win.
                if showsWaitingDot(workspace) {
                    Circle()
                        .fill(Color.gray)
                        .frame(width: 5, height: 5)
                        .offset(x: 2, y: -2)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                if workspace.title.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text("<Untitled>")
                        .font(.body.weight(.medium))
                        .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                        .lineLimit(1)
                } else {
                    Text(workspace.title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(Theme.foreground(for: colorScheme))
                        .lineLimit(1)
                }

                HStack(spacing: 8) {
                    if showRepo, let repo = workspace.repositoryName {
                        Text(repo)
                            .font(.caption)
                            .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                            .lineLimit(1)
                    }

                    if let pill = prIndicator.pill {
                        let pillColor = Self.pillColor(for: pill.status)
                        Text("PR\(pill.number.map { " #\($0)" } ?? "")")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(pillColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(pillColor.opacity(0.12))
                            .clipShape(Capsule())
                    }

                    // "+N": other monitored PRs in the pool beyond the
                    // primary pill (same capsule styling, muted).
                    if prIndicator.otherMonitorCount > 0 {
                        Text("+\(prIndicator.otherMonitorCount)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Theme.mutedForeground(for: colorScheme).opacity(0.12))
                            .clipShape(Capsule())
                    }
                }
            }

            Spacer()

            if let activity = workspace.lastActivity ?? workspace.updatedAt {
                Text(relativeDate(from: activity))
                    .font(.caption)
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .task {
            await monitorsSource.seed(workspaceId: workspace.id)
        }
    }

    // MARK: - PR pill derivation (pure, unit-tested)

    /// What the metadata line shows for PRs: the primary pill (nil renders
    /// no pill — exactly today's legacy behavior) and the "+N" count.
    struct PrIndicatorModel: Equatable {
        struct Pill: Equatable {
            let status: WorkspacePrPill.Status
            let number: Int?
        }
        let pill: Pill?
        let otherMonitorCount: Int
    }

    /// FE `WorkspaceCard` composition (PROTOCOL §6.9): primary =
    /// `selectPrimaryPr` over `pullRequests` merged with the workspace's
    /// monitors; legacy `prStatus`/`prNumber` only when the pool is empty;
    /// "+N" = `countOtherMonitors` against the primary's repo-qualified
    /// number. Like FE `mapWorkspacePRs`, an empty/absent `pullRequests`
    /// falls back to the single `activePullRequest` row before merging.
    static func derivePrIndicator(workspace: Workspace,
                                  monitors: [MonitoredPr]) -> PrIndicatorModel {
        var workspaceRepo: String?
        if let owner = workspace.repositoryOwner, let name = workspace.repositoryName,
           !owner.isEmpty, !name.isEmpty {
            workspaceRepo = "\(owner)/\(name)"
        }
        let basePrs: [WorkspacePullRequest]
        if let prs = workspace.pullRequests, !prs.isEmpty {
            basePrs = prs
        } else if let activePr = workspace.activePullRequest {
            basePrs = [activePr]
        } else {
            basePrs = []
        }
        let base = basePrs.map(WorkspacePrPill.PillPr.init)
        let pool = WorkspacePrPill.mergeMonitoredPRs(base, monitors,
                                                     workspaceRepo: workspaceRepo)
        let primary = WorkspacePrPill.selectPrimaryPr(pool)

        let pill: PrIndicatorModel.Pill?
        if let primary {
            pill = PrIndicatorModel.Pill(status: primary.status, number: primary.number)
        } else if let legacy = workspace.prStatus.flatMap(legacyPillStatus) {
            pill = PrIndicatorModel.Pill(status: legacy, number: workspace.prNumber)
        } else {
            pill = nil
        }

        let count = WorkspacePrPill.countOtherMonitors(
            monitors,
            primaryPrNumber: primary?.number ?? workspace.prNumber,
            repositoryOwner: workspace.repositoryOwner,
            repositoryName: workspace.repositoryName,
            primaryCrossRepo: primary?.crossRepo)
        return PrIndicatorModel(pill: pill, otherMonitorCount: count)
    }

    /// Legacy `workspace.prStatus` fallback: only the four known wire strings
    /// render a pill (unknown values hide it, exactly as before).
    nonisolated static func legacyPillStatus(_ raw: String) -> WorkspacePrPill.Status? {
        switch raw {
        case "Merged": return .merged
        case "Open": return .open
        case "Draft": return .draft
        case "Closed": return .closed
        default: return nil
        }
    }

    /// Existing pill color mapping (Merged purple / Open green / Draft gray /
    /// Closed red), keyed by pill bucket instead of the raw wire string.
    static func pillColor(for status: WorkspacePrPill.Status) -> Color {
        switch status {
        case .merged: return .purple
        case .open: return .green
        case .draft: return .gray
        case .closed: return .red
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        let size: CGFloat = 12
        let color = displayStatus.color

        switch displayStatus {
        case .failed:
            // Filled red circle with an xmark
            ZStack {
                Circle()
                    .fill(color)
                Image(systemName: "xmark")
                    .font(.system(size: size * 0.5, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: size, height: size)

        case .blocked:
            // Filled red circle with a minus (blocker attention request)
            ZStack {
                Circle()
                    .fill(color)
                Image(systemName: "minus")
                    .font(.system(size: size * 0.5, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: size, height: size)

        case .needsAttention:
            // Filled amber circle with exclamation mark
            ZStack {
                Circle()
                    .fill(color)
                Image(systemName: "exclamationmark")
                    .font(.system(size: size * 0.5, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: size, height: size)

        case .notStarted:
            // Empty outline circle
            Circle()
                .strokeBorder(Color.gray.opacity(0.4), lineWidth: 1.5)
                .frame(width: size, height: size)

        case .idle:
            // Empty outline circle in the idle muted color
            Circle()
                .strokeBorder(color, lineWidth: 1.5)
                .frame(width: size, height: size)

        case .inProgress:
            // Half-filled circle (right half)
            ZStack {
                Circle()
                    .stroke(color, lineWidth: 1.5)
                Circle()
                    .fill(color)
                    .clipShape(HalfCircle())
            }
            .frame(width: size, height: size)

        case .complete:
            // Filled circle with checkmark
            ZStack {
                Circle()
                    .fill(color)
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.5, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: size, height: size)

        case .prOpen, .prReady:
            // Filled circle with PR icon (prReady shows the same icon in green)
            ZStack {
                Circle()
                    .fill(color)
                Image(systemName: "arrow.triangle.pull")
                    .font(.system(size: size * 0.5, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: size, height: size)

        case .prMerged:
            // Filled circle with merge icon
            ZStack {
                Circle()
                    .fill(color)
                Image(systemName: "arrow.triangle.merge")
                    .font(.system(size: size * 0.5, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: size, height: size)

        case .unknown:
            // Neutral question mark for a wire value this build doesn't know
            ZStack {
                Circle()
                    .strokeBorder(color, lineWidth: 1.5)
                Image(systemName: "questionmark")
                    .font(.system(size: size * 0.5, weight: .bold))
                    .foregroundStyle(color)
            }
            .frame(width: size, height: size)
        }
    }

    private func relativeDate(from isoString: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: isoString) else {
            // Try without fractional seconds
            let basic = ISO8601DateFormatter()
            guard let date = basic.date(from: isoString) else { return isoString }
            return date.relativeFormatted
        }
        return date.relativeFormatted
    }
}

struct HalfCircle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addArc(center: CGPoint(x: rect.midX, y: rect.midY),
                     radius: rect.width / 2,
                     startAngle: .degrees(-90),
                     endAngle: .degrees(90),
                     clockwise: false)
        path.closeSubpath()
        return path
    }
}


// MARK: - Relative Date Formatting

extension Date {
    var relativeFormatted: String {
        let interval = Date().timeIntervalSince(self)
        if interval < 60 { return "now" }
        if interval < 3600 { return "\(Int(interval / 60))m" }
        if interval < 86400 { return "\(Int(interval / 3600))h" }
        if interval < 604800 { return "\(Int(interval / 86400))d" }
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        return formatter.string(from: self)
    }
}

