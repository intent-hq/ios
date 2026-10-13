import SwiftUI

struct WorkspaceNoteIcon: View {
    let kind: NoteRowIcon
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        Group {
            switch kind {
            case .star:
                documentIcon(.fileList)
                    .accessibilityLabel("Spec note")
            case .starWithProgressRing(let stats):
                documentIcon(.fileList)
                    .accessibilityLabel("Spec note")
                    .accessibilityValue("\(stats.completed) of \(stats.total) tasks complete")
            case .taskStatus(let status):
                checkbox(status: status)
            case .progressRing(let stats):
                TaskProgressRingView(stats: stats, size: WorkspaceDetailStyle.iconSize)
            case .document:
                documentIcon(.file)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: WorkspaceDetailStyle.iconSize, height: WorkspaceDetailStyle.iconSize)
    }

    private func documentIcon(_ resource: ImageResource) -> some View {
        Image(resource)
            .resizable()
            .scaledToFit()
            .foregroundStyle(WorkspaceDetailStyle.secondary(for: colorScheme, contrast: colorSchemeContrast))
    }

    @ViewBuilder
    private func checkbox(status: TaskDisplayStatus) -> some View {
        switch status {
        case .complete, .notStarted, .cancelled:
            RoundedRectangle(cornerRadius: WorkspaceDetailStyle.checkboxCornerRadius)
                .fill(status == .complete ? WorkspaceDetailStyle.accent : .clear)
                .overlay {
                    if status != .complete {
                        RoundedRectangle(cornerRadius: WorkspaceDetailStyle.checkboxCornerRadius)
                            .strokeBorder(Theme.border(for: colorScheme, contrast: colorSchemeContrast), lineWidth: WorkspaceDetailStyle.checkboxStrokeWidth)
                    }
                    if status != .notStarted {
                        Image(.check)
                            .resizable()
                            .scaledToFit()
                            .frame(width: WorkspaceDetailStyle.checkmarkSize, height: WorkspaceDetailStyle.checkmarkSize)
                            .foregroundStyle(status == .complete ? WorkspaceDetailStyle.onAccent : WorkspaceDetailStyle.foreground(for: colorScheme))
                            .accessibilityHidden(true)
                    }
                }
                .opacity(status == .cancelled && colorSchemeContrast == .standard ? WorkspaceDetailStyle.cancelledOpacity : 1)
                .accessibilityLabel(status.label)
        case .reviewRequired:
            Image(.eye)
                .resizable()
                .scaledToFit()
                .foregroundStyle(WorkspaceDetailStyle.secondary(for: colorScheme, contrast: colorSchemeContrast))
                .accessibilityLabel(status.label)
        default:
            TaskStatusIconView(status: status, size: WorkspaceDetailStyle.iconSize)
        }
    }
}
