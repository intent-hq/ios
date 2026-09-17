import SwiftUI

struct RootNavigationPresentation {
    struct ConversationPayload: Equatable {
        let agentId: String
        let workspaceId: String
        let agentName: String

        static let empty = Self(agentId: "", workspaceId: "", agentName: "")
    }

    struct NotePayload: Equatable {
        let noteId: String
        let workspaceId: String
        let noteTitle: String

        static let empty = Self(noteId: "", workspaceId: "", noteTitle: "")
    }

    enum DeferredEffect: Equatable {
        case pushPendingConversation
        case pushPendingNoteDetail
        case rebuildNote(NotePayload)
        case repushConversation(agentId: String)
    }

    enum CoordinatorAction: Equatable {
        case backFromNote
        case backToWorkspaceDetail
        case backToWorkspaceList
    }

    struct PresentationChange: Equatable {
        let deferredEffects: [DeferredEffect]
        let coordinatorAction: CoordinatorAction?
    }

    var showingWorkspaceDetail = false
    var showingConversation = false
    var showingNoteDetail = false
    var noteStack = NavigationPath()
    private(set) var conversationPayload = ConversationPayload.empty
    private(set) var notePayload = NotePayload.empty

    private var pendingConversationPush = false
    private var pendingNoteDetailPush = false
    private var programmaticConversationDismiss = false
    private var handledConversationRequestId = 0

    var conversationFallback: ConversationPayload? {
        conversationPayload.agentId.isEmpty ? nil : conversationPayload
    }

    mutating func synchronize(
        with screen: AppScreen,
        conversationRequestId: Int,
        isCompact: Bool,
        isRegularWidth: Bool
    ) -> [DeferredEffect] {
        switch screen {
        case let .agentConversation(agentId, workspaceId, agentName):
            return synchronizeConversation(
                agentId: agentId,
                workspaceId: workspaceId,
                agentName: agentName,
                conversationRequestId: conversationRequestId,
                isRegularWidth: isRegularWidth
            )
        case let .noteDetail(noteId, workspaceId, noteTitle):
            return synchronizeNote(
                payload: NotePayload(noteId: noteId, workspaceId: workspaceId, noteTitle: noteTitle),
                isCompact: isCompact
            )
        case .workspaceDetail:
            synchronizeWorkspaceDetail()
            return []
        default:
            resetNavigation()
            return []
        }
    }

    mutating func workspacePresentationChanged(
        isPresented: Bool,
        currentScreen: AppScreen
    ) -> PresentationChange {
        showingWorkspaceDetail = isPresented
        var effects: [DeferredEffect] = []
        if isPresented {
            if pendingConversationPush {
                effects.append(.pushPendingConversation)
            }
            if pendingNoteDetailPush {
                effects.append(.pushPendingNoteDetail)
            }
        }

        let action: CoordinatorAction?
        if !isPresented, Self.isWorkspaceDestination(currentScreen) {
            action = .backToWorkspaceList
        } else {
            action = nil
        }
        return PresentationChange(deferredEffects: effects, coordinatorAction: action)
    }

    mutating func conversationPresentationChanged(
        isPresented: Bool,
        currentScreen: AppScreen,
        suppressesProgrammaticDismissal: Bool
    ) -> CoordinatorAction? {
        showingConversation = isPresented
        if !isPresented, suppressesProgrammaticDismissal, programmaticConversationDismiss {
            programmaticConversationDismiss = false
            return nil
        }
        if !isPresented, case .agentConversation = currentScreen {
            return .backToWorkspaceDetail
        }
        return nil
    }

    mutating func notePresentationChanged(
        isPresented: Bool,
        currentScreen: AppScreen
    ) -> CoordinatorAction? {
        showingNoteDetail = isPresented
        if !isPresented, case .noteDetail = currentScreen {
            return .backFromNote
        }
        return nil
    }

    mutating func noteStackChanged(
        to newStack: NavigationPath,
        currentScreen: AppScreen
    ) -> CoordinatorAction? {
        noteStack = newStack
        if newStack.isEmpty, case .noteDetail = currentScreen {
            return .backFromNote
        }
        return nil
    }

    mutating func openCompactLinkedNote(_ payload: NotePayload) {
        notePayload = payload
    }

    mutating func openRegularLinkedNote(_ payload: NotePayload) {
        noteStack.append(Self.destination(for: payload))
    }

    mutating func applyDeferredEffect(_ effect: DeferredEffect, currentScreen: AppScreen) {
        switch effect {
        case .pushPendingConversation:
            showingConversation = true
            pendingConversationPush = false
        case .pushPendingNoteDetail:
            showingNoteDetail = true
            pendingNoteDetailPush = false
        case .rebuildNote(let payload):
            if case .noteDetail(let currentNoteId, _, _) = currentScreen,
               currentNoteId == payload.noteId {
                noteStack = NavigationPath()
                noteStack.append(Self.destination(for: payload))
            }
        case .repushConversation(let agentId):
            programmaticConversationDismiss = false
            if Self.shouldRepushConversation(
                currentScreen: currentScreen,
                pendingAgentId: agentId,
                conversationAgentId: conversationPayload.agentId
            ) {
                showingConversation = true
            }
        }
    }

    private mutating func synchronizeConversation(
        agentId: String,
        workspaceId: String,
        agentName: String,
        conversationRequestId: Int,
        isRegularWidth: Bool
    ) -> [DeferredEffect] {
        let agentChanged = conversationPayload.agentId != agentId
        let isNewRequest = handledConversationRequestId != conversationRequestId
        handledConversationRequestId = conversationRequestId
        conversationPayload = ConversationPayload(
            agentId: agentId,
            workspaceId: workspaceId,
            agentName: agentName
        )
        if !noteStack.isEmpty { noteStack = NavigationPath() }
        if showingNoteDetail { showingNoteDetail = false }

        if !showingWorkspaceDetail {
            showingWorkspaceDetail = true
            pendingConversationPush = true
        } else if !showingConversation {
            if !programmaticConversationDismiss {
                showingConversation = true
            }
        } else if isRegularWidth, agentChanged || isNewRequest {
            programmaticConversationDismiss = true
            showingConversation = false
            return [.repushConversation(agentId: agentId)]
        }
        return []
    }

    private mutating func synchronizeNote(payload: NotePayload, isCompact: Bool) -> [DeferredEffect] {
        if isCompact {
            notePayload = payload
            if showingConversation { showingConversation = false }
            if !showingWorkspaceDetail {
                showingWorkspaceDetail = true
                pendingNoteDetailPush = true
            } else if !showingNoteDetail {
                showingNoteDetail = true
            }
            return []
        }

        if showingConversation { showingConversation = false }
        if !showingWorkspaceDetail { showingWorkspaceDetail = true }
        if !noteStack.isEmpty { noteStack = NavigationPath() }
        return [.rebuildNote(payload)]
    }

    private mutating func synchronizeWorkspaceDetail() {
        if !showingWorkspaceDetail { showingWorkspaceDetail = true }
        if showingConversation { showingConversation = false }
        if showingNoteDetail { showingNoteDetail = false }
        if !noteStack.isEmpty { noteStack = NavigationPath() }
    }

    private mutating func resetNavigation() {
        if showingWorkspaceDetail { showingWorkspaceDetail = false }
        if showingConversation { showingConversation = false }
        if showingNoteDetail { showingNoteDetail = false }
        if !noteStack.isEmpty { noteStack = NavigationPath() }
    }

    private static func isWorkspaceDestination(_ screen: AppScreen) -> Bool {
        switch screen {
        case .workspaceDetail, .agentConversation, .noteDetail:
            return true
        default:
            return false
        }
    }

    private static func destination(for payload: NotePayload) -> NoteDestination {
        NoteDestination(
            noteId: payload.noteId,
            workspaceId: payload.workspaceId,
            noteTitle: payload.noteTitle
        )
    }

    private static func shouldRepushConversation(
        currentScreen: AppScreen,
        pendingAgentId: String,
        conversationAgentId: String
    ) -> Bool {
        guard conversationAgentId == pendingAgentId else { return false }
        if case .agentConversation(let agentId, _, _) = currentScreen, agentId == pendingAgentId {
            return true
        }
        return false
    }
}
