import SwiftUI

struct NoteContentView: View {
    let content: String
    var workspaceId: String?
    let resolveNote: (String) -> Note?
    var onOpenURL: ((URL) -> OpenURLAction.Result)?
    var onOpenTaskNote: (String) -> Void
    var onSetLineStatus: (Int, String) -> Void
    var onSetTaskNoteStatus: (String, String) -> Void

    var body: some View {
        let segments = NoteContentSegmenter.segments(for: content)
        let rows = segments.enumerated().map { offset, segment in
            (id: offset, content: segmentContent(segment))
        }
        VStack(alignment: .leading, spacing: Constants.Notes.Content.segmentSpacing) {
            ForEach(rows, id: \.id) { @Sendable row in
                row.content
            }
        }
    }

    @ViewBuilder
    private func segmentContent(_ segment: NoteContentSegment) -> some View {
        switch segment {
        case .markdown(let text):
            MarkdownTextView(text: text, onOpenURL: onOpenURL, workspaceId: workspaceId)
        case .taskLine(let line):
            if let linked = line.linkedTask {
                LinkedTaskCardRow(
                    line: line,
                    linked: linked,
                    resolvedNote: resolveNote(linked.noteId),
                    onOpen: { onOpenTaskNote(linked.noteId) },
                    onSetStatus: { onSetTaskNoteStatus(linked.noteId, $0) }
                )
            } else {
                PlainTaskRow(
                    line: line,
                    workspaceId: workspaceId
                ) { onSetLineStatus(line.lineNumber, $0) }
            }
        }
    }
}

private func indentPadding(_ columns: Int) -> CGFloat {
    CGFloat(min(columns, Constants.Notes.Content.maximumIndentColumns))
        * Constants.Notes.Content.indentWidthPerColumn
}

private struct PlainTaskRow: View {
    let line: NoteTaskLine
    let workspaceId: String?
    let onSetStatus: (String) -> Void

    private var nextStatus: String {
        switch line.markerStatus {
        case .notStarted: return "in-progress"
        case .inProgress: return "done"
        default: return "todo"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: Constants.Notes.Content.taskRowSpacing) {
            Button {
                onSetStatus(nextStatus)
            } label: {
                TaskStatusIconView(status: line.markerStatus, size: Constants.Notes.Content.taskIconSize)
                    .padding(.top, Constants.Notes.Content.taskIconTopPadding)
                    .contentShape(Rectangle().inset(by: -(
                        Constants.Accessibility.minimumTapTarget
                            - Constants.Notes.Content.taskIconSize
                    ) / 2))
            }
            .buttonStyle(IntentContentButtonStyle())
            .requiresLiveConnection()
            .accessibilityLabel("Change status for \(line.text)")
            .accessibilityValue(line.markerStatus.label)
            MarkdownTextView(text: line.text, workspaceId: workspaceId)
        }
        .padding(.leading, indentPadding(line.indentColumns))
    }
}

private struct LinkedTaskCardRow: View {
    let line: NoteTaskLine
    let linked: LinkedTaskRef
    let resolvedNote: Note?
    let onOpen: () -> Void
    let onSetStatus: (String) -> Void
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private static let statusOptions: [(status: TaskDisplayStatus, wire: String)] = [
        (.notStarted, "not_started"),
        (.waiting, "waiting"),
        (.discussionNeeded, "discussion_needed"),
        (.blocked, "blocked"),
        (.inProgress, "in_progress"),
        (.reviewRequired, "review_required"),
        (.complete, "complete"),
        (.cancelled, "cancelled")
    ]

    private var status: TaskDisplayStatus {
        resolvedNote?.taskDisplayStatus ?? line.markerStatus
    }

    private var title: String {
        resolvedNote?.title ?? linked.title
    }

    var body: some View {
        HStack(spacing: Constants.Notes.Content.linkedTaskSpacing) {
            statusMenu
            openTaskButton
        }
        .padding(.horizontal, Constants.Notes.Content.linkedTaskHorizontalPadding)
        .padding(.vertical, Constants.Notes.Content.linkedTaskVerticalPadding)
        .background(Theme.card(for: colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: Constants.Notes.Content.linkedTaskCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Constants.Notes.Content.linkedTaskCornerRadius)
                .stroke(
                    Theme.border(for: colorScheme),
                    lineWidth: Constants.Notes.Content.linkedTaskBorderWidth
                )
        )
        .padding(.leading, indentPadding(line.indentColumns))
    }

    private var statusMenu: some View {
        Menu {
            ForEach(Self.statusOptions, id: \.wire) { option in
                Button { onSetStatus(option.wire) } label: {
                    Text("\(option.status.emoji) \(option.status.label)")
                }
            }
        } label: {
            TaskStatusIconView(status: status, size: Constants.Notes.Content.taskIconSize)
                .frame(
                    minWidth: Constants.Accessibility.minimumTapTarget,
                    minHeight: Constants.Accessibility.minimumTapTarget
                )
        }
        .buttonStyle(IntentContentButtonStyle())
        .requiresLiveConnection()
        .accessibilityLabel("Change status for \(title)")
        .accessibilityValue(status.label)
    }

    private var openTaskButton: some View {
        Button(action: onOpen) {
            HStack(spacing: Constants.Notes.Content.linkedTaskSpacing) {
                Text(title)
                    .interFont(Constants.Typography.bodyXSEmphasized)
                    .foregroundStyle(Theme.foreground(for: colorScheme))
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                Spacer(minLength: 0)
                Image(.chevronRight)
                    .resizable()
                    .scaledToFit()
                    .frame(width: Constants.Notes.Content.taskIconSize, height: Constants.Notes.Content.taskIconSize)
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                    .accessibilityHidden(true)
            }
            .frame(
                maxWidth: .infinity,
                minHeight: Constants.Accessibility.minimumTapTarget,
                alignment: .leading
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(IntentContentButtonStyle())
        .accessibilityLabel("Open task \(title)")
    }
}
