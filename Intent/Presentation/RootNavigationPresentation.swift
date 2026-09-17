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
        case pushPendingConversation(identity: Int)
        case pushPendingNoteDetail(identity: Int)
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

    private struct PendingConversationPush: Equatable {
        let identity: Int
        let payload: ConversationPayload
        let conversationRequestId: Int
    }

    private struct PendingNoteDetailPush: Equatable {
        let identity: Int
        let payload: NotePayload
    }

    private var pendingConversationPush: PendingConversationPush?
    private var pendingNoteDetailPush: PendingNoteDetailPush?
    private var nextInitialPushIdentity = 0
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

    mutating func compactWorkspacePresentationChanged(
        isPresented: Bool,
        currentScreen: AppScreen
    ) -> PresentationChange {
        showingWorkspaceDetail = isPresented
        var effects: [DeferredEffect] = []
        if isPresented {
            if let pendingConversationPush {
                effects.append(.pushPendingConversation(identity: pendingConversationPush.identity))
            }
            if let pendingNoteDetailPush {
                effects.append(.pushPendingNoteDetail(identity: pendingNoteDetailPush.identity))
            }
        } else {
            pendingConversationPush = nil
            pendingNoteDetailPush = nil
        }

        let action: CoordinatorAction?
        if !isPresented, Self.isWorkspaceDestination(currentScreen) {
            action = .backToWorkspaceList
        } else {
            action = nil
        }
        return PresentationChange(deferredEffects: effects, coordinatorAction: action)
    }

    mutating func regularWorkspacePresentationChanged(isPresented: Bool) -> [DeferredEffect] {
        showingWorkspaceDetail = isPresented
        if isPresented, let pendingConversationPush {
            return [.pushPendingConversation(identity: pendingConversationPush.identity)]
        }
        if !isPresented {
            pendingConversationPush = nil
            pendingNoteDetailPush = nil
        }
        return []
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

    mutating func applyDeferredEffect(
        _ effect: DeferredEffect,
        currentScreen: AppScreen
    ) {
        applyDeferredEffect(
            effect,
            currentScreen: currentScreen,
            conversationRequestId: handledConversationRequestId
        )
    }

    mutating func applyDeferredEffect(
        _ effect: DeferredEffect,
        currentScreen: AppScreen,
        conversationRequestId: Int
    ) {
        switch effect {
        case .pushPendingConversation(let identity):
            guard let pendingConversationPush,
                  pendingConversationPush.identity == identity else { return }
            guard pendingConversationPush.conversationRequestId == conversationRequestId,
                  Self.matchesConversation(currentScreen, payload: pendingConversationPush.payload)
            else {
                self.pendingConversationPush = nil
                return
            }
            showingConversation = true
            self.pendingConversationPush = nil
        case .pushPendingNoteDetail(let identity):
            guard let pendingNoteDetailPush,
                  pendingNoteDetailPush.identity == identity else { return }
            guard Self.matchesNote(currentScreen, payload: pendingNoteDetailPush.payload) else {
                self.pendingNoteDetailPush = nil
                return
            }
            showingNoteDetail = true
            self.pendingNoteDetailPush = nil
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
}

private extension RootNavigationPresentation {
    private mutating func synchronizeConversation(
        agentId: String,
        workspaceId: String,
        agentName: String,
        conversationRequestId: Int,
        isRegularWidth: Bool
    ) -> [DeferredEffect] {
        let payload = ConversationPayload(
            agentId: agentId,
            workspaceId: workspaceId,
            agentName: agentName
        )
        let agentChanged = conversationPayload.agentId != agentId
        let isNewRequest = handledConversationRequestId != conversationRequestId
        handledConversationRequestId = conversationRequestId
        conversationPayload = payload
        pendingNoteDetailPush = nil
        if pendingConversationPush?.payload != payload
            || pendingConversationPush?.conversationRequestId != conversationRequestId {
            pendingConversationPush = nil
        }
        if !noteStack.isEmpty { noteStack = NavigationPath() }
        if showingNoteDetail { showingNoteDetail = false }

        if !showingWorkspaceDetail {
            showingWorkspaceDetail = true
            pendingConversationPush = PendingConversationPush(
                identity: makeInitialPushIdentity(),
                payload: payload,
                conversationRequestId: conversationRequestId
            )
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

    mutating func synchronizeNote(payload: NotePayload, isCompact: Bool) -> [DeferredEffect] {
        pendingConversationPush = nil
        if pendingNoteDetailPush?.payload != payload {
            pendingNoteDetailPush = nil
        }
        if isCompact {
            notePayload = payload
            if showingConversation { showingConversation = false }
            if !showingWorkspaceDetail {
                showingWorkspaceDetail = true
                pendingNoteDetailPush = PendingNoteDetailPush(
                    identity: makeInitialPushIdentity(),
                    payload: payload
                )
            } else if !showingNoteDetail {
                showingNoteDetail = true
            }
            return []
        }

        pendingNoteDetailPush = nil
        if showingConversation { showingConversation = false }
        if !showingWorkspaceDetail { showingWorkspaceDetail = true }
        if !noteStack.isEmpty { noteStack = NavigationPath() }
        return [.rebuildNote(payload)]
    }

    mutating func synchronizeWorkspaceDetail() {
        pendingConversationPush = nil
        pendingNoteDetailPush = nil
        if !showingWorkspaceDetail { showingWorkspaceDetail = true }
        if showingConversation { showingConversation = false }
        if showingNoteDetail { showingNoteDetail = false }
        if !noteStack.isEmpty { noteStack = NavigationPath() }
    }

    mutating func resetNavigation() {
        pendingConversationPush = nil
        pendingNoteDetailPush = nil
        if showingWorkspaceDetail { showingWorkspaceDetail = false }
        if showingConversation { showingConversation = false }
        if showingNoteDetail { showingNoteDetail = false }
        if !noteStack.isEmpty { noteStack = NavigationPath() }
    }

    static func isWorkspaceDestination(_ screen: AppScreen) -> Bool {
        switch screen {
        case .workspaceDetail, .agentConversation, .noteDetail:
            return true
        default:
            return false
        }
    }

    static func destination(for payload: NotePayload) -> NoteDestination {
        NoteDestination(
            noteId: payload.noteId,
            workspaceId: payload.workspaceId,
            noteTitle: payload.noteTitle
        )
    }

    mutating func makeInitialPushIdentity() -> Int {
        nextInitialPushIdentity += 1
        return nextInitialPushIdentity
    }

    static func matchesConversation(_ screen: AppScreen, payload: ConversationPayload) -> Bool {
        guard case let .agentConversation(agentId, workspaceId, agentName) = screen else { return false }
        return agentId == payload.agentId
            && workspaceId == payload.workspaceId
            && agentName == payload.agentName
    }

    static func matchesNote(_ screen: AppScreen, payload: NotePayload) -> Bool {
        guard case let .noteDetail(noteId, workspaceId, noteTitle) = screen else { return false }
        return noteId == payload.noteId
            && workspaceId == payload.workspaceId
            && noteTitle == payload.noteTitle
    }

    static func shouldRepushConversation(
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
