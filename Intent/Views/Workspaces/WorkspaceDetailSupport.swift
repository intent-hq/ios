import SwiftUI

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
        VStack(alignment: .leading, spacing: Constants.WorkspaceDetail.progressSectionSpacing) {
            Text(progress.summary)
                .interFont(Constants.Typography.bodyXSEmphasized)
                .foregroundStyle(Theme.foreground(for: colorScheme))
                .fixedSize(horizontal: false, vertical: true)
            progressBar
        }
        .padding(.horizontal, Constants.WorkspaceDetail.horizontalPadding)
        .padding(.bottom, Constants.WorkspaceDetail.progressBottomPadding)
    }

    private var progressBar: some View {
        HStack(spacing: Constants.WorkspaceDetail.progressSpacing) {
            progressSegment(count: progress.completed, color: .green)
            progressSegment(count: progress.inProgress, color: .blue)
            remainingProgressSegment
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Constants.WorkspaceDetail.progressHeight)
        .clipShape(RoundedRectangle(cornerRadius: Constants.WorkspaceDetail.progressCornerRadius))
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { progressWidth = $0 }
        .overlay { progressBorder }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func progressSegment(count: Int, color: Color) -> some View {
        if count > 0 {
            RoundedRectangle(cornerRadius: Constants.WorkspaceDetail.progressCornerRadius)
                .fill(color)
                .frame(width: segmentWidth(for: count))
        }
    }

    @ViewBuilder
    private var remainingProgressSegment: some View {
        if progress.remaining > 0 {
            RoundedRectangle(cornerRadius: Constants.WorkspaceDetail.progressCornerRadius)
                .fill(
                    Theme.mutedForeground(for: colorScheme, contrast: colorSchemeContrast)
                        .opacity(
                            colorSchemeContrast == .increased
                                ? Constants.WorkspaceDetail.increasedRemainingOpacity
                                : Constants.WorkspaceDetail.remainingProgressOpacity
                        )
                )
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
            RoundedRectangle(cornerRadius: Constants.WorkspaceDetail.progressCornerRadius)
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
