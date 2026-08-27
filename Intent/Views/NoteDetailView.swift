import SwiftUI

struct NoteDetailView: View {
    let noteId: String
    let workspaceId: String
    let noteTitle: String
    /// Optional closure to push a note onto the navigation stack (for note-to-note navigation).
    /// Parameters: (noteId, workspaceId, noteTitle)
    var onNavigateToNote: ((_ noteId: String, _ workspaceId: String, _ noteTitle: String) -> Void)? = nil
    @State private var noteStore = NoteStore()
    @State private var agentStore = AgentStore()
    @EnvironmentObject var coordinator: AppCoordinator
    @Environment(\.colorScheme) var colorScheme
    @State private var note: Note?
    @State private var isLoading = true

    var body: some View {
        ZStack {
            Theme.background(for: colorScheme).ignoresSafeArea()

            if isLoading {
                ProgressView("Loading note...")
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
            } else if let note = displayNote, !note.content.isEmpty || showsTaskHeader(note) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        // Tags
                        if !note.tags.isEmpty {
                            HStack(spacing: 4) {
                                ForEach(note.tags, id: \.self) { tag in
                                    Text(tag)
                                        .font(.caption)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(Theme.muted(for: colorScheme))
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                        .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                                }
                            }
                        }

                        // Task-note metadata header (status, agents, relations),
                        // matching fe NoteMetadataBar; never shown for the spec.
                        if showsTaskHeader(note) {
                            TaskMetadataHeaderView(
                                note: note,
                                notes: noteStore.notes,
                                resolveAgentName: { id in
                                    agentStore.agents.first { $0.id == id }?.name
                                },
                                resolveAgentCreatedAt: { id in
                                    ISO8601DateFormatter.lenientDate(
                                        from: agentStore.agents.first { $0.id == id }?.createdAt)
                                },
                                onNavigateToNote: { navigateToNote($0) },
                                onSetStatus: { status in
                                    Task {
                                        await noteStore.updateTaskNoteStatus(
                                            noteId: noteId, workspaceId: workspaceId,
                                            status: status)
                                    }
                                }
                            )
                        }

                        // Content: markdown segments interleaved with native task rows
                        if !note.content.isEmpty {
                            NoteContentView(
                                content: note.content,
                                resolveNote: { noteStore.note(byId: $0) },
                                onOpenURL: { url in
                                    if let link = Self.parseIntentNoteLink(url) {
                                        navigateToNote(link.id, in: link.workspaceId)
                                        return .handled
                                    }
                                    return .systemAction
                                },
                                onOpenTaskNote: { targetId in
                                    navigateToNote(targetId)
                                },
                                onSetLineStatus: { line, status in
                                    Task {
                                        await noteStore.updateTaskLineStatus(
                                            noteId: noteId, workspaceId: workspaceId,
                                            line: line, status: status)
                                    }
                                },
                                onSetTaskNoteStatus: { taskNoteId, status in
                                    Task {
                                        await noteStore.updateTaskNoteStatus(
                                            noteId: taskNoteId, workspaceId: workspaceId,
                                            status: status)
                                    }
                                }
                            )
                        }
                    }
                    .padding(16)
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "doc.text")
                        .font(.largeTitle)
                        .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                    Text("Note content unavailable")
                        .font(.headline)
                        .foregroundStyle(Theme.foreground(for: colorScheme))
                }
            }
        }
        .navigationTitle(noteTitle)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadNote()
            // Also fetch all notes so we can resolve titles for intent:// links
            await noteStore.fetchNotes(workspaceId: workspaceId)
            // Agents back the metadata header's assignee names; observe events
            // so names stay current while the note is open.
            agentStore.startObservingEvents()
            await agentStore.fetchAgents(workspaceId: workspaceId)
            noteStore.onNoteChanged = { [self] in
                Task { await self.refreshNote() }
            }
            noteStore.startObservingEvents(workspaceId: workspaceId)
        }
        .onChange(of: noteStore.notes) { _, newNotes in
            // Live-delta removal: if the open note vanished from the workspace's note
            // list while we have content loaded, confirm via refetch (which falls back
            // to the workspace detail on a definitive not-found). An empty list also
            // triggers the refetch — the last note in the workspace may have been the
            // open one — and a spurious empty publish is harmless since refreshNote
            // only navigates on a definitive not-found.
            if note != nil && !newNotes.contains(where: { $0.id == noteId }) {
                Task { await refreshNote() }
            }
        }
    }

    /// The note to render: the store's cached copy when available (so
    /// optimistic task-status updates show immediately), else the fetched one.
    private var displayNote: Note? {
        noteStore.note(byId: noteId) ?? note
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
        if let onNavigateToNote = onNavigateToNote {
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
        if segments.count >= 3, segments[1] == "task" || segments[1] == "note" {
            return (workspaceId: segments[0], id: segments[2])
        }
        return nil
    }
}

