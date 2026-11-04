import SwiftUI

struct NoteDetailView: View {
    @ScaledMetric(relativeTo: .largeTitle) private var emptyStateIconSize: CGFloat = 34
    private static let linkedNotePathComponentCount = 3
    private static let linkedNoteKindIndex = 1

    let noteId: String
    let workspaceId: String
    let noteTitle: String
    let showsBackButton: Bool
    /// Optional closure to push a note onto the navigation stack (for note-to-note navigation).
    /// Parameters: (noteId, workspaceId, noteTitle)
    var onNavigateToNote: ((_ noteId: String, _ workspaceId: String, _ noteTitle: String) -> Void)?
    @State private var noteStore: NoteStore
    @State private var agentStore: AgentStore
    @Environment(AppCoordinator.self) var coordinator
    @Environment(\.colorScheme) var colorScheme
    @State private var note: Note?
    @State private var isLoading = true

    init(
        noteId: String,
        workspaceId: String,
        noteTitle: String,
        session: BackendSession,
        showsBackButton: Bool = true,
        onNavigateToNote: ((_ noteId: String, _ workspaceId: String, _ noteTitle: String) -> Void)? = nil
    ) {
        self.noteId = noteId
        self.workspaceId = workspaceId
        self.noteTitle = noteTitle
        self.showsBackButton = showsBackButton
        self.onNavigateToNote = onNavigateToNote
        _noteStore = State(initialValue: NoteStore(connectionManager: session.connection))
        _agentStore = State(initialValue: AgentStore(connectionManager: session.connection, summaries: session.agentSummaries))
    }

    var agentStoreConnectionID: ObjectIdentifier {
        ObjectIdentifier(agentStore.connectionManager)
    }

    var noteStoreConnectionID: ObjectIdentifier {
        ObjectIdentifier(noteStore.connectionManager)
    }

    var noteStoreForTesting: NoteStore {
        noteStore
    }

    var body: some View {
        ZStack {
            WorkspaceDetailStyle.background(for: colorScheme).ignoresSafeArea()
            noteContentState
        }
        .navigationTitle(noteTitle)
        .toolbar(.visible, for: .navigationBar)
        .toolbarTitleDisplayMode(.inline)
        .intentNavigationBackButton(showsBackButton, usesWorkspaceVerticalBar: true, showsBackground: false)
        .workspaceNavigationSubtitle(title: noteTitle, workspaceId: workspaceId)
        .task {
            await loadNote()
            // Also fetch all notes so we can resolve titles for intent:// links
            await noteStore.fetchNotes(workspaceId: workspaceId)
            // The list landed after loadNote(), so its slim row (§5.2) missed
            // fetchNote's upsert — graft the fetched body onto it so
            // optimistic checkbox edits work off the cached content.
            if let fetched = note {
                noteStore.upsertFullNote(fetched, workspaceId: workspaceId)
            }
            // Agents back the metadata header's assignee names; observe events
            // so names stay current while the note is open.
            agentStore.startObservingEvents()
            await agentStore.fetchAgents(workspaceId: workspaceId)
            noteStore.startObservingEvents(workspaceId: workspaceId)
            // Refresh on note events for as long as this task lives: SwiftUI
            // cancels it when the view disappears, which ends the stream, so
            // the store never holds a reference back to the view and no stale
            // refresh runs after dismissal (ios#250).
            for await _ in noteStore.noteChanges() {
                await refreshNote()
            }
        }
        .onChange(of: noteStore.notes) { _, newNotes in
            // Live-delta removal: if the open note vanished from the workspace's note
            // list while we have content loaded, confirm via refetch (which falls back
            // to the workspace detail on a definitive not-found). An empty list also
            // triggers the refetch — the last note in the workspace may have been the
            // open one — and a spurious empty publish is harmless since refreshNote
            // only navigates on a definitive not-found.
            if note != nil, !newNotes.contains(where: { $0.id == noteId }) {
                Task { await refreshNote() }
            }
            // A slim row (§5.2) at a different revision than the fetched body
            // means the note changed between loadNote() and the list request:
            // refetch so the rendered content catches up (fetchNote's upsert
            // then clears the stale marker, ending the cycle).
            if let cached = newNotes.first(where: { $0.id == noteId }),
               cached.needsFullContent, let full = note,
               cached.updatedAt != full.updatedAt {
                Task { await refreshNote() }
            }
        }
    }

    @ViewBuilder
    private var noteContentState: some View {
        if isLoading {
            ProgressView {
                Text("Loading note...").interFont(Constants.Typography.bodyS)
            }
                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
        } else if let note = displayNote, !note.content.isEmpty || showsTaskHeader(note) {
            ScrollView { noteStack(note) }
        } else {
            VStack(spacing: Constants.Notes.Detail.contentSpacing) {
                Image(.note)
                    .resizable()
                    .scaledToFit()
                    .frame(width: emptyStateIconSize, height: emptyStateIconSize)
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                    .accessibilityHidden(true)
                Text("Note content unavailable")
                    .interFont(Constants.Typography.bodyM)
                    .foregroundStyle(Theme.foreground(for: colorScheme))
            }
        }
    }

    private func noteStack(_ note: Note) -> some View {
        VStack(alignment: .leading, spacing: Constants.Notes.Detail.contentSpacing) {
            noteTags(note)
            taskHeader(note)
            if note.contentTruncated {
                NoteTruncationNotice(shownBytes: note.content.utf8.count, totalBytes: note.contentBytes) {
                    Task { await refreshNote() }
                }
            }
            renderedContent(note)
        }
        .padding(Constants.Notes.Detail.contentPadding)
    }

    @ViewBuilder
    private func noteTags(_ note: Note) -> some View {
        if !note.tags.isEmpty {
            HStack(spacing: Constants.Notes.Detail.tagSpacing) {
                ForEach(note.tags, id: \.self) { tag in
                    Text(tag)
                        .interFont(Constants.Typography.subtextXXS)
                        .padding(.horizontal, Constants.Notes.Detail.tagHorizontalPadding)
                        .padding(.vertical, Constants.Notes.Detail.tagVerticalPadding)
                        .background(Theme.muted(for: colorScheme))
                        .clipShape(RoundedRectangle(cornerRadius: Constants.Notes.Detail.tagCornerRadius))
                        .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                }
            }
        }
    }

    @ViewBuilder
    private func taskHeader(_ note: Note) -> some View {
        if showsTaskHeader(note) {
            TaskMetadataHeaderView(
                note: note,
                notes: noteStore.notes,
                resolveAgentName: { id in agentStore.agents.first { $0.id == id }?.name },
                resolveAgentCreatedAt: { id in
                    ISO8601DateFormatter.lenientDate(
                        from: agentStore.agents.first { $0.id == id }?.createdAt
                    )
                },
                onNavigateToNote: { navigateToNote($0) },
                onSetStatus: { status in
                    Task {
                        await noteStore.updateTaskNoteStatus(
                            noteId: noteId,
                            workspaceId: workspaceId,
                            status: status
                        )
                    }
                }
            )
        }
    }

    @ViewBuilder
    private func renderedContent(_ note: Note) -> some View {
        if !note.content.isEmpty {
            NoteContentView(
                content: note.content,
                workspaceId: workspaceId,
                resolveNote: { noteStore.note(byId: $0) },
                onOpenURL: { url in
                    if let link = Self.parseIntentNoteLink(url) {
                        navigateToNote(link.id, in: link.workspaceId)
                        return .handled
                    }
                    return .systemAction
                },
                onOpenTaskNote: { navigateToNote($0) },
                onSetLineStatus: { line, status in
                    Task {
                        await noteStore.updateTaskLineStatus(
                            noteId: noteId,
                            workspaceId: workspaceId,
                            line: line,
                            status: status
                        )
                    }
                },
                onSetTaskNoteStatus: { taskNoteId, status in
                    Task {
                        await noteStore.updateTaskNoteStatus(
                            noteId: taskNoteId,
                            workspaceId: workspaceId,
                            status: status
                        )
                    }
                }
            )
        }
    }

    /// The note to render: the store's cached copy when available (so
    /// optimistic task-status updates show immediately), else the fetched one.
    /// A cached slim list row (§5.2) carries no content, and a cut list row
    /// only a prefix, so graft the fetched body onto it when it holds at
    /// least as much — the cached copy's metadata still wins. When the
    /// cached row is newer than the fetched body, this is last-known content:
    /// the onChange handler has already kicked off a refetch (same policy as
    /// refreshNote's transient-error path — never blank a rendered note).
    private var displayNote: Note? {
        guard let cached = noteStore.note(byId: noteId) else { return note }
        if cached.needsFullContent, let full = note, !full.content.isEmpty,
           full.content.utf8.count >= cached.content.utf8.count {
            return cached.withBody(of: full)
        }
        return cached
    }

    /// Whether the task-note metadata header renders: any task note except
    /// the spec. Also keeps metadata-only (empty-content) task notes on the
    /// detail view instead of the "content unavailable" placeholder.
    private func showsTaskHeader(_ note: Note) -> Bool {
        note.taskStatus != nil && !note.isDefault
    }

    /// Push a note onto the navigation stack (note-to-note navigation).
    /// A non-nil `targetWorkspaceId` (from a workspace-qualified link) routes
    /// the navigation to that workspace; nil falls back to the current one.
    private func navigateToNote(_ targetId: String, in targetWorkspaceId: String? = nil) {
        let destinationWorkspaceId = targetWorkspaceId ?? workspaceId
        let title = noteStore.note(byId: targetId)?.title ?? "Note"
        if let onNavigateToNote {
            onNavigateToNote(targetId, destinationWorkspaceId, title)
        } else {
            coordinator.onSelectNote(targetId, workspaceId: destinationWorkspaceId, noteTitle: title)
        }
    }

    private func loadNote() async {
        isLoading = true
        switch await noteStore.fetchNote(noteId: noteId, workspaceId: workspaceId) {
        case .found(let fetched):
            note = fetched
        case .notFound:
            note = nil
            coordinator.handleMissingNote(noteId: noteId, workspaceId: workspaceId)
        case .transientError:
            note = nil
        }
        isLoading = false
    }

    private func refreshNote() async {
        switch await noteStore.fetchNote(noteId: noteId, workspaceId: workspaceId) {
        case .found(let fetched):
            note = fetched
        case .notFound:
            coordinator.handleMissingNote(noteId: noteId, workspaceId: workspaceId)
        case .transientError:
            break  // keep showing the last known content
        }
    }

    /// Parse an intent:// URL to extract a note/task ID.
    /// Supports the short forms
    ///   intent://local/task/{id}
    ///   intent://local/note/{id}
    /// and the canonical workspace-qualified long forms
    ///   intent://local/{workspaceId}/task/{id}
    ///   intent://local/{workspaceId}/note/{id}
    /// Long forms carry the embedded workspace ID; short forms return nil for it
    /// (callers fall back to the current workspace).
    static func parseIntentNoteLink(_ url: URL) -> (workspaceId: String?, id: String)? {
        guard url.scheme == "intent", url.host == "local" else { return nil }
        // URL path segments: e.g. intent://local/task/abc-123 → host="local", path="/task/abc-123"
        let segments = url.pathComponents.filter { $0 != "/" }
        if segments.count >= 2, segments[0] == "task" || segments[0] == "note" {
            return (workspaceId: nil, id: segments[1])
        }
        if segments.count >= Self.linkedNotePathComponentCount,
           segments[Self.linkedNoteKindIndex] == "task" || segments[Self.linkedNoteKindIndex] == "note" {
            return (workspaceId: segments[0], id: segments[2])
        }
        return nil
    }
}
