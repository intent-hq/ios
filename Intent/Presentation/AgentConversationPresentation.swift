import SwiftUI

/// The agent conversation screen's sheets, alerts and the demo cover, plus the
/// state of a Delete the user confirmed on this screen.
struct AgentConversationPresentation: Equatable {
    /// At most one of these is open.
    enum Modal: Equatable {
        case modelPicker
        case rename(draft: String)
        case deleteConfirmation
        case note(NoteSheetInfo)
        case demoCover
    }

    /// A confirmed Delete keeps running while the menu, sheets and alerts stay
    /// usable, so it is tracked next to `modal` rather than as one of its cases.
    enum Deletion: Equatable {
        case idle
        /// The `agent.delete` request was sent from this screen and has not
        /// failed. The screen navigates away itself on success, so the
        /// `agent:deleted` fallback must not navigate too.
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

    /// The rename alert's text; empty while the alert is closed.
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

    /// True while a Delete from this screen is running or has succeeded.
    var suppressesMissingAgentFallback: Bool { deletion == .requested }

    mutating func present(_ modal: Modal) {
        self.modal = modal
    }

    /// Binding setter: clears `modal` only while it is still the closing one.
    mutating func dismiss(_ closing: Modal) {
        if modal == closing { modal = nil }
    }

    mutating func dismissRename() {
        if showsRename { modal = nil }
    }

    mutating func dismissNote() {
        if note != nil { modal = nil }
    }

    /// The user confirmed Delete.
    mutating func beginDeletion() {
        deletion = .requested
    }

    /// The `agent.delete` request failed; the fallback applies again.
    mutating func deletionFailed() {
        deletion = .idle
    }
}

extension Binding where Value == AgentConversationPresentation {
    /// Clearing applies only while `modal` is still the closing one.
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
