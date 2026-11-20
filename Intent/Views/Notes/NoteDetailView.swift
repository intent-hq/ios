import SwiftUI

struct NoteDetailView: View {
    @ScaledMetric(relativeTo: .largeTitle) private var emptyStateIconSize: CGFloat = 34
    private static let linkedNotePathComponentCount = 3
    private static let linkedNoteKindIndex = 1

    let noteId: String
    let workspaceId: String
    let noteTitle: String
    let showsBackButton: Bool
    var onInlineBack: (() -> Void)?
    var inlineBackLabel: LocalizedStringKey = "Back"
    var onNavigateToNote: ((_ noteId: String, _ workspaceId: String, _ noteTitle: String) -> Void)?
    @State private var noteStore: NoteStore
    @State private var agentStore: AgentStore
    @Environment(AppCoordinator.self) var coordinator
    @Environment(BackendSession.self) private var session
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.isRemoteReadOnly) private var isRemoteReadOnly
    @State private var note: Note?
    @State private var isLoading = true

    init(
        noteId: String,
        workspaceId: String,
        noteTitle: String,
        session: BackendSession,
        showsBackButton: Bool = true,
        onNavigateToNote: ((_ noteId: String, _ workspaceId: String, _ noteTitle: String) -> Void)? = nil,
        onInlineBack: (() -> Void)? = nil,
        inlineBackLabel: LocalizedStringKey = "Back"
    ) {
        self.noteId = noteId
        self.workspaceId = workspaceId
        self.noteTitle = noteTitle
        self.showsBackButton = showsBackButton
        self.onInlineBack = onInlineBack
        self.inlineBackLabel = inlineBackLabel
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
            VStack(spacing: 0) {
                if let onInlineBack { inlineHeader(onBack: onInlineBack) }
                noteContentState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(noteTitle)
        .toolbar(onInlineBack == nil ? .visible : .hidden, for: .navigationBar)
        .toolbarTitleDisplayMode(.inline)
        .intentNavigationBackButton(showsBackButton, usesWorkspaceVerticalBar: true, showsBackground: false)
        .workspaceNavigationSubtitle(title: noteTitle, workspaceId: workspaceId)
        .onChange(of: isRemoteReadOnly) { _, readOnly in
            guard !readOnly, displayNote?.content.isEmpty ?? true else { return }
            Task { await loadNote() }
        }
        .task {
            await loadNote()
            await noteStore.fetchNotes(workspaceId: workspaceId)
            if let fetched = note {
                noteStore.upsertFullNote(fetched, workspaceId: workspaceId)
            }
            agentStore.startObservingEvents()
            await agentStore.fetchAgents(workspaceId: workspaceId)
            noteStore.startObservingEvents(workspaceId: workspaceId)
            for await _ in noteStore.noteChanges() {
                await refreshNote()
            }
        }
        .onChange(of: noteStore.notes) { _, newNotes in
            if note != nil, !newNotes.contains(where: { $0.id == noteId }) {
                Task { await refreshNote() }
            }
            if let cached = newNotes.first(where: { $0.id == noteId }),
               cached.needsFullContent, let full = note,
               cached.updatedAt != full.updatedAt {
                Task { await refreshNote() }
            }
        }
    }

    private func inlineHeader(onBack: @escaping () -> Void) -> some View {
        let workspaceTitle = WorkspaceSubtitleResolver.subtitle(
            forWorkspaceId: workspaceId,
            in: session.workspaceStore.workspaces
        )
        return WorkspaceNavigationHeader(
            title: noteTitle,
            subtitle: workspaceTitle.map { (title: String) -> LocalizedStringKey in "\(title)" },
            backLabel: inlineBackLabel,
            backIdentifier: "note.back",
            titleIdentifier: "note.header.title",
            showsBackground: false,
            usesConversationLayout: true,
            onBack: onBack
        ) {
            Color.clear
                .frame(width: WorkspaceDetailStyle.controlSize, height: WorkspaceDetailStyle.controlSize)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var noteContentState: some View {
        if let note = displayNote, !note.content.isEmpty || showsTaskHeader(note), !isLoading || isRemoteReadOnly {
            ScrollView { noteStack(note) }
        } else if isRemoteReadOnly {
            AvailableWhenReconnectedView()
        } else if isLoading {
            ProgressView {
                Text("Loading note...").interFont(Constants.Typography.bodyS)
            }
                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
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

    private var displayNote: Note? {
        guard let cached = noteStore.note(byId: noteId) else { return note }
        if cached.needsFullContent, let full = note, !full.content.isEmpty,
           full.content.utf8.count >= cached.content.utf8.count {
            return cached.withBody(of: full)
        }
        return cached
    }

    private func showsTaskHeader(_ note: Note) -> Bool {
        note.taskStatus != nil && !note.isDefault
    }

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
            break
        }
    }

    static func parseIntentNoteLink(_ url: URL) -> (workspaceId: String?, id: String)? {
        guard url.scheme == "intent", url.host == "local" else { return nil }
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
