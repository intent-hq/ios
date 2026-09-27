import SwiftUI

struct WorkspaceDetailHeading: View {
    let title: String
    let repositoryOwner: String?
    let repositoryName: String?
    var statusMessage: String?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: WorkspaceDetailStyle.headingSpacing) {
            Text(title)
                .interFont(Constants.Typography.heading2)
                .tracking(WorkspaceDetailStyle.titleTracking)
                .foregroundStyle(WorkspaceDetailStyle.foreground(for: colorScheme))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if let repositoryOwner, let repositoryName {
                Text("\(repositoryOwner)/\(repositoryName)")
                    .interFont(Constants.Typography.subtextXXS)
                    .foregroundStyle(colorScheme == .light && colorSchemeContrast == .standard
                        ? WorkspaceDetailStyle.neutral
                        : WorkspaceDetailStyle.secondary(for: colorScheme, contrast: colorSchemeContrast))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let summary = statusMessage?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
                Text(summary)
                    .interFont(Constants.Typography.bodyS)
                    .tracking(WorkspaceDetailStyle.bodyTracking)
                    .foregroundStyle(WorkspaceDetailStyle.secondary(for: colorScheme, contrast: colorSchemeContrast))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("workspaceDetail.summary")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, WorkspaceDetailStyle.pageInset)
        .padding(.top, dynamicTypeSize.isAccessibilitySize ? WorkspaceDetailStyle.headingSpacing : WorkspaceDetailStyle.headingTopSpacing)
        .padding(.bottom, WorkspaceDetailStyle.headingBottomSpacing)
    }
}

struct WorkspaceTaskProgressLayout: Equatable {
    let total: Int
    let completed: Int
    let inProgress: Int
    let remaining: Int

    init?(total: Int, completed: Int, inProgress: Int) {
        guard total > 0 else { return nil }
        self.total = total
        self.completed = min(max(0, completed), total)
        self.inProgress = min(max(0, inProgress), total - self.completed)
        self.remaining = total - self.completed - self.inProgress
    }

    var visibleSegmentCount: Int {
        [completed, inProgress, remaining].count { $0 > 0 }
    }

    var summary: String {
        "\(completed) of \(total) tasks complete"
            + (inProgress > 0 ? ", \(inProgress) in progress" : "")
    }

    func segmentWidth(
        for count: Int,
        in measuredWidth: CGFloat,
        spacing: CGFloat
    ) -> CGFloat {
        let totalSpacing = spacing * CGFloat(max(0, visibleSegmentCount - 1))
        let distributableWidth = max(0, measuredWidth - totalSpacing)
        return distributableWidth * CGFloat(count) / CGFloat(total)
    }
}

struct WorkspaceTaskProgressView: View {
    let progress: WorkspaceTaskProgressLayout

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @State private var progressWidth: CGFloat = 0

    var body: some View {
        progressBar
            .padding(.horizontal, WorkspaceDetailStyle.pageInset)
            .padding(.bottom, WorkspaceDetailStyle.progressBottomSpacing)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Task progress")
            .accessibilityValue(progress.summary)
    }

    private var progressBar: some View {
        HStack(spacing: Constants.WorkspaceDetail.progressSpacing) {
            progressSegment(count: progress.completed, color: WorkspaceDetailStyle.foreground(for: colorScheme))
            progressSegment(count: progress.inProgress, color: WorkspaceDetailStyle.accent)
            remainingProgressSegment
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: WorkspaceDetailStyle.progressHeight)
        .clipShape(Capsule())
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { progressWidth = $0 }
        .overlay { progressBorder }
    }

    @ViewBuilder
    private func progressSegment(count: Int, color: Color) -> some View {
        if count > 0 {
            Rectangle()
                .fill(color)
                .frame(width: segmentWidth(for: count))
        }
    }

    @ViewBuilder
    private var remainingProgressSegment: some View {
        if progress.remaining > 0 {
            Rectangle()
                .fill(WorkspaceDetailStyle.surface(for: colorScheme))
                .frame(width: segmentWidth(for: progress.remaining))
        }
    }

    private func segmentWidth(for count: Int) -> CGFloat {
        progressWidth > 0
            ? progress.segmentWidth(
                for: count,
                in: progressWidth,
                spacing: Constants.WorkspaceDetail.progressSpacing
            )
            : 0
    }

    @ViewBuilder
    private var progressBorder: some View {
        if colorSchemeContrast == .increased {
            Capsule()
                .strokeBorder(
                    Theme.border(for: colorScheme, contrast: colorSchemeContrast),
                    lineWidth: Constants.WorkspaceDetail.increasedContrastProgressBorderWidth
                )
        }
    }
}

enum WorkspaceDetailHeaderLayout {
    static func tabTopPadding(hasTaskProgress: Bool) -> CGFloat {
        hasTaskProgress ? 0 : Constants.WorkspaceDetail.tabVerticalPadding
    }
}

struct WorkspaceActionsMenu: View {
    let isTerminalDisabled: Bool
    let onCreateAgent: () -> Void
    let onCreateTerminal: () -> Void
    let onArchive: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Menu {
            Button(action: onCreateAgent) {
                Label { Text("Create New Agent").interFont(Constants.Typography.bodyS) } icon: { Image(.addCircle) }
            }
            Button(action: onCreateTerminal) {
                Label { Text("New terminal").interFont(Constants.Typography.bodyS) } icon: { Image(systemName: "terminal") }
            }
            .disabled(isTerminalDisabled)
            Divider()
            Button(action: onArchive) {
                Label { Text("Archive").interFont(Constants.Typography.bodyS) } icon: { Image(.archive) }
            }
            Button(role: .destructive, action: onDelete) {
                Label { Text("Delete").interFont(Constants.Typography.bodyS) } icon: { Image(.delete) }
            }
        } label: {
            ToolbarOverflowLabel()
        }
        .accessibilityLabel("Workspace actions")
    }
}

#if os(visionOS)
struct WorkspaceActionConfirmationSheet: View {
    let title: String
    let message: String
    let actionLabel: String
    let isDestructive: Bool
    let onConfirm: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: Constants.WorkspaceDetail.confirmationSheetSpacing) {
            Text(title).interFont(Constants.Typography.heading2)
            Text(message).interFont(Constants.Typography.bodyS)
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
            Button(role: isDestructive ? .destructive : nil) {
                dismiss()
                onConfirm()
            } label: {
                Text(actionLabel).interFont(Constants.Typography.bodyS)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            Button {
                dismiss()
            } label: {
                Text("Cancel").interFont(Constants.Typography.bodyS)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .padding(Constants.WorkspaceDetail.confirmationSheetPadding)
        .frame(width: Constants.WorkspaceDetail.confirmationSheetWidth)
    }
}
#endif
