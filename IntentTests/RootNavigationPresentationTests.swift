// swiftlint:disable file_length
@testable import Intent
import SwiftUI
import Testing

@Suite @MainActor
struct RootNavigationPresentationTests {}

extension RootNavigationPresentationTests {
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

        let change = presentation.compactWorkspacePresentationChanged(
            isPresented: true,
            currentScreen: screen
        )
        #expect(change.deferredEffects.count == 1)
        #expect(isPendingConversationPush(change.deferredEffects[0]))

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
        let change = presentation.compactWorkspacePresentationChanged(
            isPresented: true,
            currentScreen: screen
        )
        #expect(change.deferredEffects.count == 1)
        #expect(isPendingNoteDetailPush(change.deferredEffects[0]))
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

    @Test func regularSameAgentNewRequestRepushesConversation() {
        var presentation = presentedConversation(agentId: "agent-A", requestId: 1)
        let screen = conversationScreen(agentId: "agent-A")

        let effects = presentation.synchronize(
            with: screen,
            conversationRequestId: 2,
            isCompact: false,
            isRegularWidth: true
        )

        #expect(effects == [.repushConversation(agentId: "agent-A")])
        #expect(!presentation.showingConversation)
    }

    @Test func regularUnchangedPresentedConversationDoesNotRepush() {
        var presentation = presentedConversation(agentId: "agent-A", requestId: 1)

        let effects = presentation.synchronize(
            with: conversationScreen(agentId: "agent-A"),
            conversationRequestId: 1,
            isCompact: false,
            isRegularWidth: true
        )

        #expect(effects.isEmpty)
        #expect(presentation.showingConversation)
    }

    @Test func compactAgentAndRequestChangeDoesNotRepushConversation() {
        var presentation = presentedConversation(
            agentId: "agent-A",
            requestId: 1,
            isCompact: true,
            isRegularWidth: false
        )

        let effects = presentation.synchronize(
            with: conversationScreen(agentId: "agent-B"),
            conversationRequestId: 2,
            isCompact: true,
            isRegularWidth: false
        )

        #expect(effects.isEmpty)
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
}

extension RootNavigationPresentationTests {
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
        presentation.applyDeferredEffect(
            .repushConversation(agentId: "agent-B"),
            currentScreen: screen
        )
        #expect(presentation.showingConversation)
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

    @Test func staleRegularRepushAfterPayloadChangesAgentIsDropped() {
        var presentation = presentedConversation(agentId: "agent-A", requestId: 1)
        let pendingScreen = conversationScreen(agentId: "agent-B")
        let effects = presentation.synchronize(
            with: pendingScreen,
            conversationRequestId: 2,
            isCompact: false,
            isRegularWidth: true
        )
        _ = presentation.synchronize(
            with: conversationScreen(agentId: "agent-C"),
            conversationRequestId: 3,
            isCompact: false,
            isRegularWidth: true
        )

        presentation.applyDeferredEffect(effects[0], currentScreen: pendingScreen)

        #expect(!presentation.showingConversation)
        #expect(presentation.conversationPayload.agentId == "agent-C")
    }

    @Test func staleRegularRepushAfterCoordinatorChangesAgentIsDropped() {
        var presentation = presentedConversation(agentId: "agent-A", requestId: 1)
        let effects = presentation.synchronize(
            with: conversationScreen(agentId: "agent-B"),
            conversationRequestId: 2,
            isCompact: false,
            isRegularWidth: true
        )

        presentation.applyDeferredEffect(
            effects[0],
            currentScreen: conversationScreen(agentId: "agent-C")
        )

        #expect(!presentation.showingConversation)
        #expect(presentation.conversationPayload.agentId == "agent-B")
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
}

extension RootNavigationPresentationTests {
    @Test func regularNoteTeardownObserverBeforeDeferredRebuildNavigatesBack() {
        var presentation = RootNavigationPresentation()
        let firstScreen = noteScreen(noteId: "note-A")
        let firstEffects = presentation.synchronize(
            with: firstScreen,
            conversationRequestId: 0,
            isCompact: false,
            isRegularWidth: true
        )
        presentation.applyDeferredEffect(firstEffects[0], currentScreen: firstScreen)

        let nextScreen = noteScreen(noteId: "note-B")
        let rebuildEffects = presentation.synchronize(
            with: nextScreen,
            conversationRequestId: 0,
            isCompact: false,
            isRegularWidth: true
        )
        #expect(presentation.noteStack.isEmpty)
        #expect(
            presentation.noteStackChanged(to: NavigationPath(), currentScreen: nextScreen) == .backFromNote
        )

        presentation.applyDeferredEffect(
            rebuildEffects[0],
            currentScreen: .workspaceDetail(workspaceId: "workspace-1")
        )
        #expect(presentation.noteStack.isEmpty)
    }

    @Test func regularWorkspaceObserverDoesNotConsumePendingCompactNotePush() {
        var presentation = RootNavigationPresentation()
        let note = noteScreen(noteId: "note-A")
        _ = presentation.synchronize(
            with: note,
            conversationRequestId: 0,
            isCompact: true,
            isRegularWidth: false
        )

        #expect(presentation.regularWorkspacePresentationChanged(isPresented: true).isEmpty)

        let compactChange = presentation.compactWorkspacePresentationChanged(
            isPresented: true,
            currentScreen: note
        )
        #expect(compactChange.deferredEffects.count == 1)
        #expect(isPendingNoteDetailPush(compactChange.deferredEffects[0]))
        #expect(compactChange.coordinatorAction == nil)
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
}

private extension RootNavigationPresentationTests {
    private func presentedConversation(
        agentId: String,
        requestId: Int,
        isCompact: Bool = false,
        isRegularWidth: Bool = true
    ) -> RootNavigationPresentation {
        let screen = conversationScreen(agentId: agentId)
        var presentation = RootNavigationPresentation()
        _ = presentation.synchronize(
            with: screen,
            conversationRequestId: requestId,
            isCompact: isCompact,
            isRegularWidth: isRegularWidth
        )
        let effects: [RootNavigationPresentation.DeferredEffect]
        if isCompact {
            effects = presentation.compactWorkspacePresentationChanged(
                isPresented: true,
                currentScreen: screen
            ).deferredEffects
        } else {
            effects = presentation.regularWorkspacePresentationChanged(isPresented: true)
        }
        for effect in effects {
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

    private func isPendingConversationPush(_ effect: RootNavigationPresentation.DeferredEffect) -> Bool {
        if case .pushPendingConversation = effect { return true }
        return false
    }

    private func isPendingNoteDetailPush(_ effect: RootNavigationPresentation.DeferredEffect) -> Bool {
        if case .pushPendingNoteDetail = effect { return true }
        return false
    }
}

extension RootNavigationPresentationTests {
    @Test func conversationPushAfterRouteCancellationIsDropped() {
        let screen = conversationScreen()
        var presentation = stagedConversation(screen: screen, requestId: 1)
        let effect = pendingEffects(from: &presentation, screen: screen)[0]

        presentation.applyDeferredEffect(effect, currentScreen: .workspaceList)

        #expect(!presentation.showingConversation)
    }

    @Test func compactNotePushAfterWorkspaceOverviewIsDropped() {
        let screen = noteScreen(noteId: "note-A")
        var presentation = stagedNote(screen: screen)
        let effect = pendingEffects(from: &presentation, screen: screen)[0]
        _ = presentation.synchronize(
            with: .workspaceDetail(workspaceId: "workspace-1"),
            conversationRequestId: 0,
            isCompact: true,
            isRegularWidth: false
        )

        presentation.applyDeferredEffect(
            effect,
            currentScreen: .workspaceDetail(workspaceId: "workspace-1")
        )

        #expect(!presentation.showingNoteDetail)
    }

    @Test func staleConversationPushDoesNotConsumeSameDestinationReplacement() {
        let screen = conversationScreen()
        var presentation = stagedConversation(screen: screen, requestId: 1)
        let staleEffect = pendingEffects(from: &presentation, screen: screen)[0]
        cancel(&presentation, conversationRequestId: 1)
        _ = presentation.synchronize(
            with: screen,
            conversationRequestId: 2,
            isCompact: true,
            isRegularWidth: false
        )
        let replacementEffect = pendingEffects(from: &presentation, screen: screen)[0]

        presentation.applyDeferredEffect(staleEffect, currentScreen: screen)
        #expect(!presentation.showingConversation)
        presentation.applyDeferredEffect(replacementEffect, currentScreen: screen)
        #expect(presentation.showingConversation)
    }

    @Test func conversationPushChecksLiveSameDestinationRequest() {
        let screen = conversationScreen()
        var presentation = stagedConversation(screen: screen, requestId: 1)
        let effect = pendingEffects(from: &presentation, screen: screen)[0]

        presentation.applyDeferredEffect(
            effect,
            currentScreen: screen,
            conversationRequestId: 2
        )

        #expect(!presentation.showingConversation)
    }

    @Test(arguments: ["note-A", "note-B"])
    func staleNotePushDoesNotConsumeReplacement(replacementNoteId: String) {
        let firstScreen = noteScreen(noteId: "note-A")
        var presentation = stagedNote(screen: firstScreen)
        let staleEffect = pendingEffects(from: &presentation, screen: firstScreen)[0]
        cancel(&presentation, conversationRequestId: 0)
        let replacementScreen = noteScreen(noteId: replacementNoteId)
        _ = presentation.synchronize(
            with: replacementScreen,
            conversationRequestId: 0,
            isCompact: true,
            isRegularWidth: false
        )
        let replacementEffect = pendingEffects(from: &presentation, screen: replacementScreen)[0]

        presentation.applyDeferredEffect(staleEffect, currentScreen: replacementScreen)
        #expect(!presentation.showingNoteDetail)
        presentation.applyDeferredEffect(replacementEffect, currentScreen: replacementScreen)
        #expect(presentation.showingNoteDetail)
        #expect(presentation.notePayload.noteId == replacementNoteId)
    }

    @Test func repeatedConversationSynchronizationAndDeliveryRemainValid() {
        let screen = conversationScreen()
        var presentation = stagedConversation(screen: screen, requestId: 1)
        let firstEffects = pendingEffects(from: &presentation, screen: screen)
        let synchronizationEffects = presentation.synchronize(
            with: screen,
            conversationRequestId: 1,
            isCompact: true,
            isRegularWidth: false
        )
        let repeatedEffects = pendingEffects(from: &presentation, screen: screen)

        #expect(synchronizationEffects.isEmpty)
        #expect(firstEffects == repeatedEffects)
        presentation.applyDeferredEffect(firstEffects[0], currentScreen: screen)
        #expect(presentation.showingConversation)
        presentation.applyDeferredEffect(repeatedEffects[0], currentScreen: screen)
        #expect(presentation.showingConversation)
    }
}

private extension RootNavigationPresentationTests {
    func stagedConversation(screen: AppScreen, requestId: Int) -> RootNavigationPresentation {
        var presentation = RootNavigationPresentation()
        _ = presentation.synchronize(
            with: screen,
            conversationRequestId: requestId,
            isCompact: true,
            isRegularWidth: false
        )
        return presentation
    }

    func stagedNote(screen: AppScreen) -> RootNavigationPresentation {
        var presentation = RootNavigationPresentation()
        _ = presentation.synchronize(
            with: screen,
            conversationRequestId: 0,
            isCompact: true,
            isRegularWidth: false
        )
        return presentation
    }

    func pendingEffects(
        from presentation: inout RootNavigationPresentation,
        screen: AppScreen
    ) -> [RootNavigationPresentation.DeferredEffect] {
        presentation.compactWorkspacePresentationChanged(
            isPresented: true,
            currentScreen: screen
        ).deferredEffects
    }

    func cancel(_ presentation: inout RootNavigationPresentation, conversationRequestId: Int) {
        _ = presentation.synchronize(
            with: .workspaceList,
            conversationRequestId: conversationRequestId,
            isCompact: true,
            isRegularWidth: false
        )
    }

    func conversationScreen() -> AppScreen {
        .agentConversation(
            agentId: "agent-A",
            workspaceId: "workspace-1",
            agentName: "agent-A"
        )
    }
}
