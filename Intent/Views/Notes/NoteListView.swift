import SwiftUI

struct NoteListView: View {
    let workspaceId: String
    @Environment(AppCoordinator.self) var coordinator
    var noteStore: NoteStore
    @Environment(\.colorScheme) var colorScheme
    @State private var collapsedIds: Set<String> = []

    var body: some View {
        if noteStore.isLoading || !noteStore.hasLoaded, noteStore.notes.isEmpty {
            Spacer()
            ProgressView("Loading notes...")
                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
            Spacer()
        } else if noteStore.sortedNotes.isEmpty {
            ContentUnavailableView(
                "No Notes",
                systemImage: "doc.text",
                description: Text("Notes will appear here when created.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(noteStore.rootNotes) { note in
                        NoteTreeNodeView(
                            note: note,
                            noteStore: noteStore,
                            workspaceId: workspaceId,
                            depth: 0,
                            collapsedIds: $collapsedIds,
                            colorScheme: colorScheme
                        )
                        .environment(coordinator)
                    }
                }
                .padding(.horizontal, Constants.Notes.List.horizontalPadding)
            }
            .refreshable {
                await noteStore.fetchNotes(workspaceId: workspaceId)
            }
        }
    }
}

// MARK: - Tree Node View (recursive)

struct NoteTreeNodeView: View {
    let note: Note
    let noteStore: NoteStore
    let workspaceId: String
    let depth: Int
    @Binding var collapsedIds: Set<String>
    let colorScheme: ColorScheme
    @Environment(AppCoordinator.self) var coordinator

    private var hasChildren: Bool {
        noteStore.hasChildren(note.id)
    }

    private var isCollapsed: Bool {
        collapsedIds.contains(note.id)
    }

    private var children: [Note] {
        noteStore.childNotes(of: note.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            // This note's row — chevron and title have separate tap targets
            NoteRowView(
                note: note,
                allNotes: noteStore.notes,
                depth: depth,
                hasChildren: hasChildren,
                isCollapsed: isCollapsed,
                colorScheme: colorScheme,
                onToggleCollapse: toggleCollapse
            ) {
                coordinator.onSelectNote(note.id, workspaceId: workspaceId, noteTitle: note.title)
            }

            // Children (if expanded)
            if hasChildren, !isCollapsed {
                ForEach(children) { child in
                    Self(
                        note: child,
                        noteStore: noteStore,
                        workspaceId: workspaceId,
                        depth: depth + 1,
                        collapsedIds: $collapsedIds,
                        colorScheme: colorScheme
                    )
                    .environment(coordinator)
                }
            }
        }
    }

    private func toggleCollapse() {
        withAnimation(.easeInOut(duration: Constants.Notes.List.expansionAnimationDuration)) {
            if collapsedIds.contains(note.id) {
                collapsedIds.remove(note.id)
            } else {
                collapsedIds.insert(note.id)
            }
        }
    }
}

// MARK: - Note Row View

struct NoteRowView: View {
    let note: Note
    /// Full note list, used to resolve linked-task IDs for the progress
    /// ring; recomputed on every NoteStore publish so the ring stays live.
    var allNotes: [Note] = []
    var depth: Int = 0
    var hasChildren: Bool = false
    var isCollapsed: Bool = false
    let colorScheme: ColorScheme
    var onToggleCollapse: (() -> Void)?
    var onNavigate: (() -> Void)?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var usesAccessibilityLayout: Bool {
        dynamicTypeSize.isAccessibilitySize
    }

    var body: some View {
        HStack(alignment: .top, spacing: Constants.Notes.List.rowSpacing) {
            indentation
            disclosure
            noteButton
        }
        .padding(
            .vertical,
            depth == 0
            ? Constants.Notes.List.rootVerticalPadding
            : Constants.Notes.List.nestedVerticalPadding
        )
        .padding(.trailing, Constants.Notes.List.horizontalRowPadding)
    }

    @ViewBuilder
    private var indentation: some View {
        if depth > 0 {
            Spacer()
                .frame(width: NoteRowLayout.indentation(
                    for: depth,
                    usesAccessibilityLayout: usesAccessibilityLayout
                ))
        }
    }

    @ViewBuilder
    private var disclosure: some View {
        if hasChildren {
            Button { onToggleCollapse?() } label: {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                    .padding(.top, NoteRowLayout.firstLineIconTopPadding)
                    .frame(
                        width: NoteRowLayout.disclosureTargetSize,
                        height: NoteRowLayout.disclosureTargetSize,
                        alignment: .top
                    )
                    .contentShape(Rectangle())
                    .accessibilityHidden(true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Child notes for \(note.title)")
            .accessibilityValue(isCollapsed ? "Collapsed" : "Expanded")
        } else if NoteRowLayout.reservesDisclosureSpace(
            depth: depth,
            hasChildren: hasChildren,
            usesAccessibilityLayout: usesAccessibilityLayout
        ) {
            Spacer().frame(width: NoteRowLayout.disclosureTargetSize)
        }
    }

    private var noteButton: some View {
        Button { onNavigate?() } label: {
            HStack(alignment: .top, spacing: Constants.Notes.List.contentSpacing) {
                leadingIcon
                titleAndTags
                Spacer()
            }
            .frame(
                minWidth: Constants.Accessibility.minimumTapTarget,
                maxWidth: .infinity,
                minHeight: Constants.Accessibility.minimumTapTarget,
                alignment: .leading
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var leadingIcon: some View {
        Group {
            switch NoteRowIcon.kind(for: note, notes: allNotes) {
            case .star:
                starIcon
            case .starWithProgressRing(let stats):
                starIcon
                TaskProgressRingView(stats: stats)
            case .taskStatus(let status):
                TaskStatusIconView(status: status, size: NoteRowLayout.leadingIconSize)
            case .progressRing(let stats):
                TaskProgressRingView(stats: stats)
            case .document:
                Image(systemName: "doc.text")
                    .font(.caption)
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                    .accessibilityHidden(true)
            }
        }
        .padding(.top, NoteRowLayout.firstLineIconTopPadding)
    }

    private var titleAndTags: some View {
        VStack(alignment: .leading, spacing: Constants.Notes.List.titleSpacing) {
            Text(note.title)
                .font(depth == 0 ? .headline : .body)
                .foregroundStyle(Theme.foreground(for: colorScheme))
                .lineLimit(NoteRowLayout.titleLineLimit(
                    usesAccessibilityLayout: usesAccessibilityLayout
                ))
            let visibleTags = NoteRowLayout.visibleTags(for: note)
            if !visibleTags.isEmpty {
                HStack(spacing: Constants.Notes.List.contentSpacing) {
                    ForEach(visibleTags.prefix(Constants.Notes.List.maximumTagCount), id: \.self) { tag in
                        Text(tag)
                            .font(.caption)
                            .padding(.horizontal, Constants.Notes.List.tagHorizontalPadding)
                            .padding(.vertical, Constants.Notes.List.tagVerticalPadding)
                            .background(Theme.muted(for: colorScheme))
                            .clipShape(RoundedRectangle(cornerRadius: Constants.Notes.List.tagCornerRadius))
                            .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                    }
                }
            } else if depth == 0, let preview = note.preview {
                Text(preview)
                    .font(.caption)
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                    .lineLimit(NoteRowLayout.previewLineLimit)
            }
        }
    }

    private var starIcon: some View {
        Image(systemName: "star.fill")
            .font(.caption)
            .foregroundStyle(.yellow)
            .accessibilityLabel("Spec note")
    }
}

enum NoteRowLayout {
    static let leadingIconSize: CGFloat = 14
    static let previewLineLimit = 2
    static let firstLineIconTopPadding = Constants.Notes.List.titleSpacing

    static var disclosureTargetSize: CGFloat {
        max(Constants.Notes.List.disclosureSize, Constants.Accessibility.minimumTapTarget)
    }

    static func indentation(for depth: Int, usesAccessibilityLayout: Bool) -> CGFloat {
        let width = usesAccessibilityLayout
            ? Constants.Notes.List.contentSpacing * 2
            : Constants.Notes.List.indentationWidth
        return CGFloat(max(0, depth)) * width
    }

    /// Nested leaves keep the disclosure slot at every text size so their
    /// content never starts left of the parent's (which sits after its own
    /// disclosure button).
    static func reservesDisclosureSpace(
        depth: Int,
        hasChildren: Bool,
        usesAccessibilityLayout: Bool = false
    ) -> Bool {
        depth > 0 && !hasChildren && !usesAccessibilityLayout
    }

    /// Leading edge of the row's content button, mirroring the spacers and
    /// disclosure slot laid out in `NoteRowView.body`.
    static func contentLeadingOffset(
        depth: Int,
        hasChildren: Bool,
        usesAccessibilityLayout: Bool
    ) -> CGFloat {
        var offset: CGFloat = 0
        if depth > 0 {
            offset += indentation(for: depth, usesAccessibilityLayout: usesAccessibilityLayout)
                + Constants.Notes.List.rowSpacing
        }
        if hasChildren || reservesDisclosureSpace(depth: depth, hasChildren: hasChildren) {
            offset += disclosureTargetSize + Constants.Notes.List.rowSpacing
        }
        return offset
    }

    static func titleLineLimit(usesAccessibilityLayout: Bool) -> Int? {
        usesAccessibilityLayout ? nil : 2
    }

    static func visibleTags(for note: Note) -> [String] {
        guard note.isDefault else { return note.tags }
        let title = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return note.tags.filter { tag in
            tag.trimmingCharacters(in: .whitespacesAndNewlines)
                .localizedCaseInsensitiveCompare(title) != .orderedSame
        }
    }
}
