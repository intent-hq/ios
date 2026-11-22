import Foundation

nonisolated struct ConversationGoalDraft: Equatable, Sendable {
    var text: String
    var failure: String?
}

nonisolated enum ConversationGoalStripState: Equatable, Sendable {
    case collapsed
    case editing(ConversationGoalDraft)
    case expanded
    case removing
    case saving(ConversationGoalDraft)

    var isExpanded: Bool { self == .expanded }

    var isRemoving: Bool { self == .removing }

    var isEditorPresented: Bool {
        switch self {
        case .editing, .saving: true
        case .collapsed, .expanded, .removing: false
        }
    }

    var isSaving: Bool {
        if case .saving = self { return true }
        return false
    }

    var draft: ConversationGoalDraft? {
        switch self {
        case let .editing(draft), let .saving(draft): draft
        case .collapsed, .expanded, .removing: nil
        }
    }

    var canSave: Bool {
        if case .editing = self { return true }
        return false
    }

    mutating func toggleExpansion() {
        switch self {
        case .collapsed: self = .expanded
        case .expanded: self = .collapsed
        case .editing, .removing, .saving: break
        }
    }

    mutating func beginEditing(goal: String) {
        guard !isEditorPresented, !isRemoving else { return }
        self = .editing(ConversationGoalDraft(text: goal))
    }

    mutating func updateDraft(_ text: String) {
        guard case var .editing(draft) = self else { return }
        draft.text = text
        draft.failure = nil
        self = .editing(draft)
    }

    mutating func cancelEditing() {
        guard case .editing = self else { return }
        self = .collapsed
    }

    mutating func beginSaving() -> String? {
        guard canSave, case let .editing(draft) = self else { return nil }
        self = .saving(draft)
        return draft.text
    }

    mutating func finishSaving(failure: String?) {
        guard case var .saving(draft) = self else { return }
        if let failure {
            draft.failure = failure
            self = .editing(draft)
        } else {
            self = .collapsed
        }
    }

    mutating func beginRemoving() -> Bool {
        guard !isEditorPresented, !isRemoving else { return false }
        self = .removing
        return true
    }

    mutating func finishRemoving() {
        guard isRemoving else { return }
        self = .collapsed
    }
}
