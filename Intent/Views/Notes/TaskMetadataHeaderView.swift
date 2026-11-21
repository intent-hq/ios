import SwiftUI

struct TaskMetadataHeaderView: View {
    let note: Note
    let notes: [Note]
    let resolveAgentName: (String) -> String?
    let resolveAgentCreatedAt: (String) -> Date?
    let onNavigateToNote: (String) -> Void
    let onSetStatus: (String) -> Void
    @Environment(\.colorScheme) var colorScheme

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

    static func dependedOnBy(noteId: String, in notes: [Note]) -> [String] {
        notes
            .filter { !$0.isArchived && $0.id != noteId && $0.dependsOn.contains(noteId) }
            .map(\.id)
            .sorted()
    }

    static func showsUnmetDependency(_ depId: String, note: Note) -> Bool {
        note.taskStatus != "complete" && note.unmetDependsOn.contains(depId)
    }

    static func sortedAssigneeIds(
        _ ids: [String],
        createdAt: (String) -> Date?
    ) -> [String] {
        var seen = Set<String>()
        let unique = ids.filter { seen.insert($0).inserted }
        return unique
            .enumerated()
            .sorted { firstAssignee, secondAssignee in
                let dateA = createdAt(firstAssignee.element) ?? .distantFuture
                let dateB = createdAt(secondAssignee.element) ?? .distantFuture
                if dateA != dateB { return dateA < dateB }
                return firstAssignee.offset < secondAssignee.offset
            }
            .map(\.element)
    }

    var body: some View {
        let dependents = Self.dependedOnBy(noteId: note.id, in: notes)
        VStack(alignment: .leading, spacing: Constants.Notes.Metadata.sectionSpacing) {
            row("Status") { statusMenu }
            if !note.assignedAgentIds.isEmpty {
                row("Agent") { agentNames }
            }
            if !note.dependsOn.isEmpty {
                row("Depends on") {
                    chips(note.dependsOn) { depId in
                        (
                            variant: ChipVariant.dependency,
                            unmet: Self.showsUnmetDependency(depId, note: note)
                        )
                    }
                }
            }
            if !dependents.isEmpty {
                row("Depended on by") {
                    chips(dependents) { _ in (variant: .dependency, unmet: false) }
                }
            }
            if !note.conflictsWith.isEmpty {
                row("Conflicts with") {
                    chips(note.conflictsWith) { _ in (variant: .conflict, unmet: false) }
                }
            }
            Divider()
        }
    }

    // MARK: - Rows

    private func row(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: .top, spacing: Constants.Notes.Metadata.rowSpacing) {
            Text(label)
                .interFont(Constants.Typography.bodyXS)
                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                .frame(width: Constants.Notes.Metadata.labelWidth, alignment: .leading)
                .padding(.vertical, Constants.Notes.Metadata.verticalPadding)
            content()
            Spacer(minLength: 0)
        }
    }

    private var statusMenu: some View {
        Menu {
            ForEach(Self.statusOptions, id: \.wire) { option in
                Button {
                    onSetStatus(option.wire)
                } label: {
                    Text("\(option.status.emoji) \(option.status.label)")
                }
            }
        } label: {
            HStack(spacing: Constants.Notes.Metadata.relationSpacing) {
                TaskStatusIconView(
                    status: note.taskDisplayStatus ?? .unknown,
                    size: Constants.Notes.Metadata.statusIconSize
                )
                Text((note.taskDisplayStatus ?? .unknown).label)
                    .interFont(Constants.Typography.bodyXSEmphasized)
                    .foregroundStyle(Theme.foreground(for: colorScheme))
            }
            .padding(.vertical, Constants.Notes.Metadata.verticalPadding)
            .frame(minHeight: Constants.Accessibility.minimumTapTarget)
        }
        .buttonStyle(IntentContentButtonStyle())
        .requiresLiveConnection()
        .accessibilityLabel("Change task status")
        .accessibilityValue((note.taskDisplayStatus ?? .unknown).label)
    }

    private var agentNames: some View {
        let rows = Self.sortedAssigneeIds(note.assignedAgentIds, createdAt: resolveAgentCreatedAt).map { agentId in
            let content = Text(resolveAgentName(agentId) ?? Self.truncatedId(agentId))
                .interFont(Constants.Typography.bodyXSEmphasized)
                .foregroundStyle(Theme.foreground(for: colorScheme))
                .lineLimit(1)
                .padding(.horizontal, Constants.Notes.Metadata.chipHorizontalPadding)
                .padding(.vertical, Constants.Notes.Metadata.verticalPadding)
                .background(Theme.muted(for: colorScheme))
                .clipShape(RoundedRectangle(cornerRadius: Constants.Notes.Metadata.chipCornerRadius))
            return (id: agentId, content: content)
        }
        return VStack(alignment: .leading, spacing: Constants.Notes.Metadata.chipStackSpacing) {
            ForEach(rows, id: \.id) { @Sendable row in
                row.content
            }
        }
    }

    private func chips(
        _ ids: [String],
        style: @escaping (String) -> (variant: ChipVariant, unmet: Bool)
    ) -> some View {
        VStack(alignment: .leading, spacing: Constants.Notes.Metadata.chipStackSpacing) {
            ForEach(ids, id: \.self) { relatedId in
                let chipStyle = style(relatedId)
                TaskRelationChip(
                    relatedNote: notes.first { $0.id == relatedId },
                    fallbackId: relatedId,
                    variant: chipStyle.variant,
                    unmet: chipStyle.unmet
                ) { onNavigateToNote(relatedId) }
            }
        }
    }

    static func truncatedId(_ id: String) -> String {
        id.count <= Constants.Notes.Metadata.fallbackIdMaximumLength
            ? id
            : String(id.prefix(Constants.Notes.Metadata.fallbackIdMaximumLength)) + "…"
    }
}

enum ChipVariant {
    case conflict
    case dependency
}

private struct TaskRelationChip: View {
    @ScaledMetric(relativeTo: .caption2) private var warningIconSize: CGFloat = 11
    let relatedNote: Note?
    let fallbackId: String
    let variant: ChipVariant
    let unmet: Bool
    let onTap: () -> Void
    @Environment(\.colorScheme) var colorScheme

    private static let warning = TaskStatusIconView.Palette.amber

    private var title: String {
        relatedNote?.title ?? fallbackId
    }

    var body: some View {
        Button(action: onTap) {
            chipLabel
            .padding(.horizontal, Constants.Notes.Metadata.chipHorizontalPadding)
            .padding(.vertical, Constants.Notes.Metadata.verticalPadding)
            .background(
                variant == .conflict
                    ? Self.warning.opacity(Constants.Notes.Metadata.warningBackgroundOpacity)
                    : unmet
                        ? Theme.muted(for: colorScheme)
                        : Theme.muted(for: colorScheme).opacity(
                            Constants.Notes.Metadata.mutedBackgroundOpacity
                        )
            )
            .clipShape(RoundedRectangle(cornerRadius: Constants.Notes.Metadata.chipCornerRadius))
            .frame(
                minWidth: Constants.Accessibility.minimumTapTarget,
                minHeight: Constants.Accessibility.minimumTapTarget
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(IntentContentButtonStyle())
        .accessibilityLabel("Open related task \(title)")
        .accessibilityValue(
            variant == .conflict ? "Conflict" : unmet ? "Unmet dependency" : "Dependency"
        )
    }

    private var chipLabel: some View {
        HStack(spacing: Constants.Notes.Metadata.relationSpacing) {
            relationIcon
            Text(title)
                .interFont(Constants.Typography.bodyXSEmphasized)
                .italic(relatedNote == nil)
                .foregroundStyle(
                    variant == .conflict ? Self.warning : Theme.mutedForeground(for: colorScheme)
                )
                .lineLimit(1)
            if variant == .dependency, unmet {
                Image(systemName: "hourglass")
                    .font(.caption2)
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                    .accessibilityHidden(true)
            }
        }
    }

    @ViewBuilder
    private var relationIcon: some View {
        if variant == .conflict {
            Image(.attentionCircle)
                .resizable()
                .scaledToFit()
                .frame(width: warningIconSize, height: warningIconSize)
                .foregroundStyle(Self.warning)
                .accessibilityHidden(true)
        } else {
            TaskStatusIconView(
                status: relatedNote?.taskDisplayStatus ?? .unknown,
                size: Constants.Notes.Metadata.relationIconSize
            )
        }
    }
}
