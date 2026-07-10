import SwiftUI

struct NoteDetailView: View {
    let noteId: String
    let workspaceId: String
    let noteTitle: String
    /// Optional closure to push a note onto the navigation stack (for note-to-note navigation).
    /// Parameters: (noteId, workspaceId, noteTitle)
    var onNavigateToNote: ((_ noteId: String, _ workspaceId: String, _ noteTitle: String) -> Void)? = nil
    @StateObject private var noteStore = NoteStore()
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
            } else if let note = note, !note.renderedContent.isEmpty {
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

                        // Markdown content
                        MarkdownTextView(text: note.renderedContent, onOpenURL: { url in
                            if let targetId = Self.parseIntentNoteLink(url) {
                                let title = noteStore.note(byId: targetId)?.title ?? "Note"
                                if let onNavigateToNote = onNavigateToNote {
                                    onNavigateToNote(targetId, workspaceId, title)
                                } else {
                                    coordinator.onSelectNote(targetId, workspaceId: workspaceId, noteTitle: title)
                                }
                                return .handled
                            }
                            return .systemAction
                        })
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
            noteStore.onNoteChanged = { [self] in
                Task { await self.refreshNote() }
            }
            noteStore.startObservingEvents(workspaceId: workspaceId)
        }
    }

    private func loadNote() async {
        isLoading = true
        note = await noteStore.fetchNote(noteId: noteId, workspaceId: workspaceId)
        isLoading = false
    }

    private func refreshNote() async {
        note = await noteStore.fetchNote(noteId: noteId, workspaceId: workspaceId)
    }

    /// Parse an intent:// URL to extract a note/task ID.
    /// Supports:
    ///   intent://local/task/{id}
    ///   intent://local/note/{id}
    static func parseIntentNoteLink(_ url: URL) -> String? {
        guard url.scheme == "intent" else { return nil }
        // URL path segments: e.g. intent://local/task/abc-123 → host="local", path="/task/abc-123"
        let host = url.host
        guard host == "local" else { return nil }
        let segments = url.pathComponents.filter { $0 != "/" }
        guard segments.count >= 2 else { return nil }
        let resourceType = segments[0]
        let resourceId = segments[1]
        if resourceType == "task" || resourceType == "note" {
            return resourceId
        }
        return nil
    }
}

