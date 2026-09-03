import SwiftUI

struct NoteListView: View {
    let workspaceId: String
    @Environment(AppCoordinator.self) var coordinator
    var noteStore: NoteStore
    @Environment(\.colorScheme) var colorScheme
    @State private var collapsedIds: Set<String> = []

    var body: some View {
        if (noteStore.isLoading || !noteStore.hasLoaded) && noteStore.notes.isEmpty {
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
                onToggleCollapse: {
                    withAnimation(.easeInOut(duration: Constants.Notes.List.expansionAnimationDuration)) {
                        if collapsedIds.contains(note.id) {
                            collapsedIds.remove(note.id)
                        } else {
                            collapsedIds.insert(note.id)
                        }
                    }
                },
                onNavigate: {
                    coordinator.onSelectNote(note.id, workspaceId: workspaceId, noteTitle: note.title)
                }
            )

            // Children (if expanded)
            if hasChildren && !isCollapsed {
                ForEach(children) { child in
                    NoteTreeNodeView(
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
    var onToggleCollapse: (() -> Void)? = nil
    var onNavigate: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: Constants.Notes.List.rowSpacing) {
            // Indentation
            if depth > 0 {
                Spacer()
                    .frame(width: CGFloat(depth) * Constants.Notes.List.indentationWidth)
            }

            // Disclosure chevron (or spacer for alignment)
            if hasChildren {
                Button {
                    onToggleCollapse?()
                } label: {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                        .frame(width: Constants.Notes.List.disclosureSize,
                               height: Constants.Notes.List.disclosureSize)
                        .contentShape(Rectangle().inset(by: -(
                            Constants.Accessibility.minimumTapTarget
                                - Constants.Notes.List.disclosureSize) / 2))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Child notes for \(note.title)")
                .accessibilityValue(isCollapsed ? "Collapsed" : "Expanded")
            } else if depth > 0 {
                // Leaf node at non-root level: small spacer for alignment
                Spacer()
                    .frame(width: Constants.Notes.List.disclosureSize)
            }

            // Tappable title/content area — navigates to the note
            Button {
                onNavigate?()
            } label: {
                HStack(spacing: Constants.Notes.List.contentSpacing) {
                    // Leading icon (fe NotesPanel parity)
                    switch NoteRowIcon.kind(for: note, notes: allNotes) {
                    case .star:
                        starIcon
                    case .starWithProgressRing(let stats):
                        starIcon
                        TaskProgressRingView(stats: stats)
                    case .taskStatus(let status):
                        TaskStatusIconView(status: status, size: 14)
                    case .progressRing(let stats):
                        TaskProgressRingView(stats: stats)
                    case .document:
                        Image(systemName: "doc.text")
                            .font(.caption)
                            .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                    }

                    // Title and content
                    VStack(alignment: .leading, spacing: Constants.Notes.List.titleSpacing) {
                        Text(note.title)
                            .font(depth == 0 ? .body.weight(.medium) : .subheadline.weight(.medium))
                            .foregroundStyle(Theme.foreground(for: colorScheme))
                            .lineLimit(2)

                        if !note.tags.isEmpty {
                            HStack(spacing: Constants.Notes.List.contentSpacing) {
                                ForEach(note.tags.prefix(Constants.Notes.List.maximumTagCount), id: \.self) { tag in
                                    Text(tag)
                                        .font(.caption)
                                        .padding(.horizontal, Constants.Notes.List.tagHorizontalPadding)
                                        .padding(.vertical, Constants.Notes.List.tagVerticalPadding)
                                        .background(Theme.muted(for: colorScheme))
                                        .clipShape(RoundedRectangle(
                                            cornerRadius: Constants.Notes.List.tagCornerRadius))
                                        .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                                }
                            }
                        } else if depth == 0, let preview = note.preview {
                            Text(preview)
                                .font(.caption)
                                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                                .lineLimit(2)
                        }
                    }

                    Spacer()
                }
                .frame(
                    minWidth: Constants.Accessibility.minimumTapTarget,
                    maxWidth: .infinity,
                    minHeight: Constants.Accessibility.minimumTapTarget,
                    alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, depth == 0
            ? Constants.Notes.List.rootVerticalPadding
            : Constants.Notes.List.nestedVerticalPadding)
        .padding(.horizontal, Constants.Notes.List.horizontalRowPadding)
    }

    private var starIcon: some View {
        Image(systemName: "star.fill")
            .font(.caption)
            .foregroundStyle(.yellow)
    }
}

