import SwiftUI

struct AgentConversationPresentation: Equatable {
    enum Modal: Equatable {
        case modelPicker
        case rename(draft: String)
        case deleteConfirmation
        case note(NoteSheetInfo)
        case demoCover
    }

    enum Deletion: Equatable {
        case idle
        case requested
    }

    private(set) var modal: Modal?
    private(set) var deletion: Deletion = .idle

    var showsModelPicker: Bool { modal == .modelPicker }
    var showsDeleteConfirmation: Bool { modal == .deleteConfirmation }
    var showsDemoCover: Bool { modal == .demoCover }

    var showsRename: Bool {
        if case .rename = modal { return true }
        return false
    }

    var renameDraft: String {
        get {
            if case .rename(let draft) = modal { return draft }
            return ""
        }
        set {
            if case .rename = modal { modal = .rename(draft: newValue) }
        }
    }

    var note: NoteSheetInfo? {
        if case .note(let note) = modal { return note }
        return nil
    }

    var suppressesMissingAgentFallback: Bool { deletion == .requested }

    mutating func present(_ modal: Modal) {
        self.modal = modal
    }

    mutating func dismiss(_ closing: Modal) {
        if modal == closing { modal = nil }
    }

    mutating func dismissRename() {
        if showsRename { modal = nil }
    }

    mutating func dismissNote() {
        if note != nil { modal = nil }
    }

    mutating func beginDeletion() {
        deletion = .requested
    }

    mutating func deletionFailed() {
        deletion = .idle
    }
}

extension Binding where Value == AgentConversationPresentation {
    func presenting(_ modal: AgentConversationPresentation.Modal) -> Binding<Bool> {
        Binding<Bool>(
            get: { wrappedValue.modal == modal },
            set: { presented in
                if presented { wrappedValue.present(modal) } else { wrappedValue.dismiss(modal) }
            }
        )
    }

    var presentingRename: Binding<Bool> {
        Binding<Bool>(
            get: { wrappedValue.showsRename },
            set: { if !$0 { wrappedValue.dismissRename() } }
        )
    }

    var presentedNote: Binding<NoteSheetInfo?> {
        Binding<NoteSheetInfo?>(
            get: { wrappedValue.note },
            set: { note in
                if let note { wrappedValue.present(.note(note)) } else { wrappedValue.dismissNote() }
            }
        )
    }
}
