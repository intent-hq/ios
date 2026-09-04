import Foundation

struct NoteDestination: Hashable {
    let id: UUID
    let noteId: String
    let workspaceId: String
    let noteTitle: String

    init(noteId: String, workspaceId: String, noteTitle: String) {
        self.id = UUID()
        self.noteId = noteId
        self.workspaceId = workspaceId
        self.noteTitle = noteTitle
    }

    static func == (lhs: NoteDestination, rhs: NoteDestination) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

struct AgentDestination: Hashable, Identifiable {
    let id: UUID
    let agentId: String
    let workspaceId: String
    let agentName: String

    init(agentId: String, workspaceId: String, agentName: String) {
        self.id = UUID()
        self.agentId = agentId
        self.workspaceId = workspaceId
        self.agentName = agentName
    }

    static func == (lhs: AgentDestination, rhs: AgentDestination) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}