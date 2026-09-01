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
            Spacer()
            VStack(spacing: 12) {
                Image(systemName: "doc.text")
                    .font(.largeTitle)
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                Text("No notes")
                    .font(.headline)
                    .foregroundStyle(Theme.foreground(for: colorScheme))
                Text("Notes will appear here when created.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
            }
            Spacer()
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
                .padding(.horizontal, 16)
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
                    withAnimation(.easeInOut(duration: 0.2)) {
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

    private let indentWidth: CGFloat = 24

    var body: some View {
        HStack(spacing: 6) {
            // Indentation
            if depth > 0 {
                Spacer()
                    .frame(width: CGFloat(depth) * indentWidth)
            }

            // Disclosure chevron (or spacer for alignment)
            if hasChildren {
                Button {
                    onToggleCollapse?()
                } label: {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(isCollapsed ? "Expand" : "Collapse") \(note.title)")
            } else if depth > 0 {
                // Leaf node at non-root level: small spacer for alignment
                Spacer()
                    .frame(width: 28)
            }

            // Tappable title/content area — navigates to the note
            Button {
                onNavigate?()
            } label: {
                HStack(spacing: 4) {
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
                    VStack(alignment: .leading, spacing: 2) {
                        Text(note.title)
                            .font(depth == 0 ? .body.weight(.medium) : .subheadline.weight(.medium))
                            .foregroundStyle(Theme.foreground(for: colorScheme))
                            .lineLimit(1)

                        if !note.tags.isEmpty {
                            HStack(spacing: 4) {
                                ForEach(note.tags.prefix(3), id: \.self) { tag in
                                    Text(tag)
                                        .font(.caption2)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Theme.muted(for: colorScheme))
                                        .clipShape(RoundedRectangle(cornerRadius: 4))
                                        .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                                }
                            }
                        } else if depth == 0, let preview = note.preview {
                            Text(preview)
                                .font(.caption)
                                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                                .lineLimit(1)
                        }
                    }

                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, depth == 0 ? 10 : 9)
        .padding(.horizontal, 4)
    }

    private var starIcon: some View {
        Image(systemName: "star.fill")
            .font(.caption)
            .foregroundStyle(.yellow)
    }
}

