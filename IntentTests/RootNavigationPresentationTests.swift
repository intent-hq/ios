@testable import Intent
import SwiftUI
import Testing

@Suite @MainActor
struct RootNavigationPresentationTests {
    @Test func compactConversationStagesWorkspaceBeforeDeferredPush() {
        let screen = conversationScreen(agentId: "agent-A")
        var presentation = RootNavigationPresentation()

        let synchronizationEffects = presentation.synchronize(
            with: screen,
            conversationRequestId: 1,
            isCompact: true,
            isRegularWidth: false
        )

        #expect(synchronizationEffects.isEmpty)
        #expect(presentation.showingWorkspaceDetail)
        #expect(!presentation.showingConversation)
        #expect(presentation.conversationPayload.agentId == "agent-A")

        let change = presentation.workspacePresentationChanged(
            isPresented: true,
            currentScreen: screen
        )
        #expect(change.deferredEffects == [.pushPendingConversation])

        presentation.applyDeferredEffect(change.deferredEffects[0], currentScreen: screen)
        #expect(presentation.showingConversation)
    }

    @Test func compactNoteStagesPushAndReplacesLinkedNotePayload() {
        let screen = noteScreen(noteId: "note-A")
        var presentation = RootNavigationPresentation()

        _ = presentation.synchronize(
            with: screen,
            conversationRequestId: 0,
            isCompact: true,
            isRegularWidth: false
        )
        let change = presentation.workspacePresentationChanged(
            isPresented: true,
            currentScreen: screen
        )
        #expect(change.deferredEffects == [.pushPendingNoteDetail])
        presentation.applyDeferredEffect(change.deferredEffects[0], currentScreen: screen)
        #expect(presentation.showingNoteDetail)

        presentation.openCompactLinkedNote(notePayload(noteId: "note-B"))
        #expect(presentation.notePayload.noteId == "note-B")
        #expect(presentation.noteStack.isEmpty)
        #expect(
            presentation.notePresentationChanged(isPresented: false, currentScreen: screen) == .backFromNote
        )
    }

    @Test func regularAgentSwitchWaitsForDeferredRepushAcrossDuplicateSync() {
        var presentation = presentedConversation(agentId: "agent-A", requestId: 1)
        let screen = conversationScreen(agentId: "agent-B")

        let effects = presentation.synchronize(
            with: screen,
            conversationRequestId: 2,
            isCompact: false,
            isRegularWidth: true
        )
        #expect(effects == [.repushConversation(agentId: "agent-B")])
        #expect(!presentation.showingConversation)

        let duplicateEffects = presentation.synchronize(
            with: screen,
            conversationRequestId: 2,
            isCompact: false,
            isRegularWidth: true
        )
        #expect(duplicateEffects.isEmpty)
        #expect(!presentation.showingConversation)

        let action = presentation.conversationPresentationChanged(
            isPresented: false,
            currentScreen: screen,
            suppressesProgrammaticDismissal: true
        )
        #expect(action == nil)
        presentation.applyDeferredEffect(effects[0], currentScreen: screen)
        #expect(presentation.showingConversation)
        #expect(presentation.conversationPayload.agentId == "agent-B")
    }

    @Test func dismissalCallbackBeforeDuplicateSyncPreservesImmediateRepushOrdering() {
        var presentation = presentedConversation(agentId: "agent-A", requestId: 1)
        let screen = conversationScreen(agentId: "agent-B")

        let effects = presentation.synchronize(
            with: screen,
            conversationRequestId: 2,
            isCompact: false,
            isRegularWidth: true
        )
        _ = presentation.conversationPresentationChanged(
            isPresented: false,
            currentScreen: screen,
            suppressesProgrammaticDismissal: true
        )
        let duplicateEffects = presentation.synchronize(
            with: screen,
            conversationRequestId: 2,
            isCompact: false,
            isRegularWidth: true
        )

        #expect(duplicateEffects.isEmpty)
        #expect(
            presentation.showingConversation,
            "Existing ordering allows the second sync to present before the deferred effect"
        )
        presentation.applyDeferredEffect(effects[0], currentScreen: screen)
        #expect(presentation.showingConversation)
    }

    @Test func programmaticDismissalIsSuppressedButUserDismissalNavigatesBack() {
        var presentation = presentedConversation(agentId: "agent-A", requestId: 1)
        let screen = conversationScreen(agentId: "agent-B")
        _ = presentation.synchronize(
            with: screen,
            conversationRequestId: 2,
            isCompact: false,
            isRegularWidth: true
        )

        let programmaticAction = presentation.conversationPresentationChanged(
            isPresented: false,
            currentScreen: screen,
            suppressesProgrammaticDismissal: true
        )
        let userAction = presentation.conversationPresentationChanged(
            isPresented: false,
            currentScreen: screen,
            suppressesProgrammaticDismissal: true
        )

        #expect(programmaticAction == nil)
        #expect(userAction == .backToWorkspaceDetail)
    }

    @Test func staleRegularRepushAfterBackIsDropped() {
        var presentation = presentedConversation(agentId: "agent-A", requestId: 1)
        let screen = conversationScreen(agentId: "agent-B")
        let effects = presentation.synchronize(
            with: screen,
            conversationRequestId: 2,
            isCompact: false,
            isRegularWidth: true
        )

        presentation.applyDeferredEffect(
            effects[0],
            currentScreen: .workspaceDetail(workspaceId: "workspace-1")
        )

        #expect(!presentation.showingConversation)
    }

    @Test func unspecifiedWidthDoesNotTriggerRegularRepush() {
        var presentation = presentedConversation(
            agentId: "agent-A",
            requestId: 1,
            isRegularWidth: false
        )

        let effects = presentation.synchronize(
            with: conversationScreen(agentId: "agent-A"),
            conversationRequestId: 2,
            isCompact: false,
            isRegularWidth: false
        )

        #expect(effects.isEmpty)
        #expect(presentation.showingConversation)
    }

    @Test func regularNoteLinksAppendHistoryAndOnlyEmptyPathNavigatesBack() {
        let screen = noteScreen(noteId: "note-A")
        var presentation = RootNavigationPresentation()
        let effects = presentation.synchronize(
            with: screen,
            conversationRequestId: 0,
            isCompact: false,
            isRegularWidth: true
        )
        #expect(effects == [.rebuildNote(notePayload(noteId: "note-A"))])
        presentation.applyDeferredEffect(effects[0], currentScreen: screen)
        #expect(presentation.noteStack.count == 1)

        presentation.openRegularLinkedNote(notePayload(noteId: "note-B"))
        #expect(presentation.noteStack.count == 2)

        var remainingPath = NavigationPath()
        remainingPath.append(NoteDestination(noteId: "note-A", workspaceId: "workspace-1", noteTitle: "A"))
        #expect(presentation.noteStackChanged(to: remainingPath, currentScreen: screen) == nil)
        #expect(
            presentation.noteStackChanged(to: NavigationPath(), currentScreen: screen) == .backFromNote
        )
    }

    @Test func initialDeferredPushRemainsUnguardedAfterRouteChanges() {
        let screen = conversationScreen(agentId: "agent-A")
        var presentation = RootNavigationPresentation()
        _ = presentation.synchronize(
            with: screen,
            conversationRequestId: 1,
            isCompact: true,
            isRegularWidth: false
        )
        let change = presentation.workspacePresentationChanged(
            isPresented: true,
            currentScreen: screen
        )

        presentation.applyDeferredEffect(
            change.deferredEffects[0],
            currentScreen: .workspaceList
        )

        #expect(
            presentation.showingConversation,
            "The ownership refactor intentionally preserves the pre-existing unguarded initial push"
        )
    }

    @Test func separatePresentationInstancesRemainIndependent() {
        var firstWindow = RootNavigationPresentation()
        var secondWindow = RootNavigationPresentation()

        _ = firstWindow.synchronize(
            with: conversationScreen(agentId: "agent-A"),
            conversationRequestId: 1,
            isCompact: true,
            isRegularWidth: false
        )
        secondWindow.openCompactLinkedNote(notePayload(noteId: "note-B"))

        #expect(firstWindow.showingWorkspaceDetail)
        #expect(firstWindow.conversationPayload.agentId == "agent-A")
        #expect(secondWindow.conversationFallback == nil)
        #expect(!secondWindow.showingWorkspaceDetail)
        #expect(secondWindow.notePayload.noteId == "note-B")
    }

    @Test func conversationDestinationPrefersLiveRouteThenFallsBack() {
        let fallback = RootNavigationPresentation.ConversationPayload(
            agentId: "fallback-agent",
            workspaceId: "fallback-workspace",
            agentName: "Fallback"
        )
        let live = ConversationDestinationView.resolveTarget(
            currentScreen: conversationScreen(agentId: "live-agent"),
            fallback: fallback
        )
        let retained = ConversationDestinationView.resolveTarget(
            currentScreen: .workspaceDetail(workspaceId: "workspace-1"),
            fallback: fallback
        )

        #expect(live?.agentId == "live-agent")
        #expect(retained == fallback)
    }

    private func presentedConversation(
        agentId: String,
        requestId: Int,
        isRegularWidth: Bool = true
    ) -> RootNavigationPresentation {
        let screen = conversationScreen(agentId: agentId)
        var presentation = RootNavigationPresentation()
        _ = presentation.synchronize(
            with: screen,
            conversationRequestId: requestId,
            isCompact: false,
            isRegularWidth: isRegularWidth
        )
        let change = presentation.workspacePresentationChanged(
            isPresented: true,
            currentScreen: screen
        )
        for effect in change.deferredEffects {
            presentation.applyDeferredEffect(effect, currentScreen: screen)
        }
        return presentation
    }

    private func conversationScreen(agentId: String) -> AppScreen {
        .agentConversation(
            agentId: agentId,
            workspaceId: "workspace-1",
            agentName: agentId
        )
    }

    private func noteScreen(noteId: String) -> AppScreen {
        .noteDetail(noteId: noteId, workspaceId: "workspace-1", noteTitle: noteId)
    }

    private func notePayload(noteId: String) -> RootNavigationPresentation.NotePayload {
        RootNavigationPresentation.NotePayload(
            noteId: noteId,
            workspaceId: "workspace-1",
            noteTitle: noteId
        )
    }
}
