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
        (.cancelled, "cancelled"),
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

    var body: some View {
        let dependents = Self.dependedOnBy(noteId: note.id, in: notes)
        VStack(alignment: .leading, spacing: 6) {
            row("Status") { statusMenu }
            if !note.assignedAgentIds.isEmpty {
                row("Agent") { agentNames }
            }
            if !note.dependsOn.isEmpty {
                row("Depends on") {
                    chips(note.dependsOn) { depId in
                        (variant: ChipVariant.dependency,
                         unmet: Self.showsUnmetDependency(depId, note: note))
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
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.footnote)
                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                .frame(width: 110, alignment: .leading)
                .padding(.vertical, 3)
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
            HStack(spacing: 6) {
                TaskStatusIconView(status: note.taskDisplayStatus ?? .unknown, size: 16)
                Text((note.taskDisplayStatus ?? .unknown).label)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Theme.foreground(for: colorScheme))
            }
            .padding(.vertical, 3)
        }
    }

    private var agentNames: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(note.assignedAgentIds, id: \.self) { agentId in
                Text(resolveAgentName(agentId) ?? Self.truncatedId(agentId))
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Theme.foreground(for: colorScheme))
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Theme.muted(for: colorScheme))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private func chips(
        _ ids: [String],
        style: @escaping (String) -> (variant: ChipVariant, unmet: Bool)
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(ids, id: \.self) { relatedId in
                let s = style(relatedId)
                TaskRelationChip(
                    relatedNote: notes.first { $0.id == relatedId },
                    fallbackId: relatedId,
                    variant: s.variant,
                    unmet: s.unmet,
                    onTap: { onNavigateToNote(relatedId) }
                )
            }
        }
    }

    /// Short display fallback for an unresolvable agent ID.
    static func truncatedId(_ id: String) -> String {
        id.count <= 14 ? id : String(id.prefix(14)) + "…"
    }
}

/// Relation chip variants, matching fe `TaskRelationLink.svelte`.
enum ChipVariant {
    case dependency
    case conflict
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

    // #f59e0b — fe `text-warning` treatment for conflict chips.
    private static let warning = Color(red: 0xF5 / 255, green: 0x9E / 255, blue: 0x0B / 255)

    private var title: String {
        relatedNote?.title ?? fallbackId
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                if variant == .conflict {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Self.warning)
                } else {
                    TaskStatusIconView(
                        status: relatedNote?.taskDisplayStatus ?? .unknown, size: 14)
                }
                Text(title)
                    .font(.footnote.weight(.medium))
                    .italic(relatedNote == nil)
                    .foregroundStyle(
                        variant == .conflict
                            ? Self.warning
                            : Theme.mutedForeground(for: colorScheme))
                    .lineLimit(1)
                if variant == .dependency && unmet {
                    Image(systemName: "hourglass")
                        .font(.caption2)
                        .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                variant == .conflict
                    ? Self.warning.opacity(0.12)
                    : unmet
                        ? Theme.muted(for: colorScheme)
                        : Theme.muted(for: colorScheme).opacity(0.4))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
}
