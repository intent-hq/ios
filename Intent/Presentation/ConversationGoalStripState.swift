import Foundation

nonisolated struct ConversationGoalDraft: Equatable, Sendable {
    var text: String
    var failure: String?
}

nonisolated enum ConversationGoalStripState: Equatable, Sendable {
    case collapsed
    case editing(ConversationGoalDraft)
    case expanded
    case saving(ConversationGoalDraft)

    var isExpanded: Bool { self == .expanded }

    var isEditorPresented: Bool {
        switch self {
        case .editing, .saving: true
        case .collapsed, .expanded: false
        }
    }

    var isSaving: Bool {
        if case .saving = self { return true }
        return false
    }

    var draft: ConversationGoalDraft? {
        switch self {
        case let .editing(draft), let .saving(draft): draft
        case .collapsed, .expanded: nil
        }
    }

    var canSave: Bool {
        guard case let .editing(draft) = self else { return false }
        return draft.text.trimmingCharacters(in: .whitespacesAndNewlines).count <= ConversationGoal.maximumLength
    }

    mutating func toggleExpansion() {
        switch self {
        case .collapsed: self = .expanded
        case .expanded: self = .collapsed
        case .editing, .saving: break
        }
    }

    mutating func beginEditing(goal: String) {
        guard !isEditorPresented else { return }
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
}
