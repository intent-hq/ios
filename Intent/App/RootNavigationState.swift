import SwiftUI

/// Explicit presentation state for `RootView`'s compact and regular-split
/// navigation stacks, replacing 12 parallel Boolean and empty-string `@State`
/// properties with mutually exclusive phase enums and typed targets.
struct RootNavigationState {
    enum ConversationPhase: Equatable {
        case hidden
        /// Workspace detail is mounting first; push once `showingWorkspaceDetail` settles.
        case pendingAfterWorkspaceDetail
        case presented
        /// Regular-width `NavigationStack` is tearing down to re-push on the next runloop tick.
        case repushing
    }

    enum CompactNotePhase: Equatable {
        case hidden
        /// Workspace detail is mounting first; push once `showingWorkspaceDetail` settles.
        case pendingAfterWorkspaceDetail
        case presented
    }

    var showingWorkspaceDetail = false
    var conversationPhase: ConversationPhase = .hidden
    var conversationTarget: ConversationDestinationView.Target?
    var compactNotePhase: CompactNotePhase = .hidden
    var compactNoteTarget: NoteDestination?
    var handledConversationRequestId = 0
    var noteStack = NavigationPath()

    var isShowingConversation: Bool {
        get { conversationPhase == .presented }
        set {
            if newValue {
                conversationPhase = .presented
            } else if conversationPhase != .repushing {
                conversationPhase = .hidden
            }
        }
    }

    var isShowingCompactNoteDetail: Bool {
        get { compactNotePhase == .presented }
        set { compactNotePhase = newValue ? .presented : .hidden }
    }

    var isRepushingConversation: Bool {
        conversationPhase == .repushing
    }

    mutating func clearNotes() {
        if !noteStack.isEmpty { noteStack = NavigationPath() }
        if compactNotePhase != .hidden { compactNotePhase = .hidden }
    }

    mutating func hideConversation() {
        if conversationPhase != .hidden { conversationPhase = .hidden }
    }

    mutating func reset() {
        if showingWorkspaceDetail { showingWorkspaceDetail = false }
        if conversationPhase != .hidden { conversationPhase = .hidden }
        if compactNotePhase != .hidden { compactNotePhase = .hidden }
        if !noteStack.isEmpty { noteStack = NavigationPath() }
    }
}
