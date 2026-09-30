import SwiftUI

/// Metadata header shown above a task note's content, matching the fe's
/// `NoteMetadataBar.svelte`: status (interactive), assigned agents, and
/// relation chips (depends on / depended on by / conflicts with). Rows with
/// no data are hidden; relation chips navigate to the related note.
struct TaskMetadataHeaderView: View {
    let note: Note
    /// All workspace notes (relation chip titles/statuses + reverse edges).
    let notes: [Note]
    /// Resolve an agent ID to a display name; nil when unknown.
    let resolveAgentName: (String) -> String?
    /// Resolve an agent ID to its creation date (assignee ordering); nil when unknown.
    let resolveAgentCreatedAt: (String) -> Date?
    /// Navigate to a related note by ID.
    let onNavigateToNote: (String) -> Void
    /// Write this task note's metadata status (PROTOCOL §5.4 vocabulary).
    let onSetStatus: (String) -> Void
    @Environment(\.colorScheme) var colorScheme

    /// The 8 task-note statuses (PROTOCOL §5.4) offered by the status menu.
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

    /// Reverse dependency edges computed client-side (fe parity): non-archived
    /// task notes whose `dependsOn` includes `noteId`, sorted by id for stable
    /// order. Archived notes are excluded — the note list hides them and
    /// navigating to one is treated as not found.
    static func dependedOnBy(noteId: String, in notes: [Note]) -> [String] {
        notes
            .filter { !$0.isArchived && $0.id != noteId && $0.dependsOn.contains(noteId) }
            .map(\.id)
            .sorted()
    }

    /// Whether a depends-on chip shows the unmet highlight: the dependency is
    /// in `unmetDependsOn` and the task itself is not complete (fe parity —
    /// unmet highlighting is suppressed once the task is complete).
    static func showsUnmetDependency(_ depId: String, note: Note) -> Bool {
        note.taskStatus != "complete" && note.unmetDependsOn.contains(depId)
    }

    /// Assignee ids for display (fe parity): deduplicated preserving first
    /// occurrence, then sorted by agent creation date (oldest first; agents
    /// with no resolvable date sort last, keeping their wire order).
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
        .accessibilityLabel("Change task status")
        .accessibilityValue((note.taskDisplayStatus ?? .unknown).label)
    }

    private var agentNames: some View {
        VStack(alignment: .leading, spacing: Constants.Notes.Metadata.chipStackSpacing) {
            ForEach(
                Self.sortedAssigneeIds(note.assignedAgentIds, createdAt: resolveAgentCreatedAt),
                id: \.self
            ) { agentId in
                Text(resolveAgentName(agentId) ?? Self.truncatedId(agentId))
                    .interFont(Constants.Typography.bodyXSEmphasized)
                    .foregroundStyle(Theme.foreground(for: colorScheme))
                    .lineLimit(1)
                    .padding(.horizontal, Constants.Notes.Metadata.chipHorizontalPadding)
                    .padding(.vertical, Constants.Notes.Metadata.verticalPadding)
                    .background(Theme.muted(for: colorScheme))
                    .clipShape(RoundedRectangle(cornerRadius: Constants.Notes.Metadata.chipCornerRadius))
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

    /// Short display fallback for an unresolvable agent ID.
    static func truncatedId(_ id: String) -> String {
        id.count <= Constants.Notes.Metadata.fallbackIdMaximumLength
            ? id
            : String(id.prefix(Constants.Notes.Metadata.fallbackIdMaximumLength)) + "…"
    }
}

/// Relation chip variants, matching fe `TaskRelationLink.svelte`.
enum ChipVariant {
    case conflict
    case dependency
}

/// Clickable chip linking to a related task note (fe `TaskRelationLink`):
/// live status icon (dependency) or warning triangle (conflict), title, and
/// an hourglass marker on unmet dependencies.
private struct TaskRelationChip: View {
    let relatedNote: Note?
    let fallbackId: String
    let variant: ChipVariant
    let unmet: Bool
    let onTap: () -> Void
    @Environment(\.colorScheme) var colorScheme

    // fe `text-warning` treatment for conflict chips (shared #f59e0b amber).
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
        .buttonStyle(.plain)
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
            Image(systemName: "exclamationmark.triangle")
                .font(.caption2.weight(.semibold))
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
