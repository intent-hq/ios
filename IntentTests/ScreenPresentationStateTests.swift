@testable import Intent
import Testing

struct WorkspaceChromePresentationTests {
    @Test func createWorkspaceClosesTheSwitcherAndOpensTheSheetWhenAllowed() {
        var presentation = WorkspaceChromePresentation.switcher
        presentation.createWorkspace(canCreate: true)
        #expect(presentation == .createWorkspace)
    }

    @Test func blockedCreateWorkspaceClosesOnlyTheSwitcher() {
        var presentation = WorkspaceChromePresentation.switcher
        presentation.createWorkspace(canCreate: false)
        #expect(presentation == .none)

        presentation = .connections
        presentation.createWorkspace(canCreate: false)
        #expect(presentation == .connections, "main left an open Connections sheet alone")
    }

    @Test func openingConnectionsReplacesTheSwitcher() {
        var presentation = WorkspaceChromePresentation.switcher
        presentation.setPresenting(.connections, true)
        #expect(presentation == .connections)
        #expect(!presentation.isPresenting(.switcher))
    }

    /// The drawer reports `false` when it is disabled or disappears, after the
    /// sheet that replaced it has already opened.
    @Test func lateDismissalOfAClosedPresentationKeepsItsSuccessor() {
        var presentation = WorkspaceChromePresentation.connections
        presentation.setPresenting(.switcher, false)
        #expect(presentation == .connections)
        presentation.setPresenting(.connections, false)
        #expect(presentation == .none)
    }

    @Test func coordinatorDismissalClosesOnlyCreateWorkspace() {
        var presentation = WorkspaceChromePresentation.connections
        presentation.dismissWorkspaceCreation()
        #expect(presentation == .connections)

        presentation = .createWorkspace
        presentation.dismissWorkspaceCreation()
        #expect(presentation == .none)
    }
}

struct AgentConversationPresentationTests {
    @Test func openingOneModalClosesTheOther() {
        var presentation = AgentConversationPresentation()
        presentation.present(.modelPicker)
        presentation.present(.rename(draft: "Spec Writer"))
        #expect(presentation.showsRename)
        #expect(!presentation.showsModelPicker)
        #expect(presentation.renameDraft == "Spec Writer")
    }

    @Test func renameDraftEditsOnlyWhileTheAlertIsOpen() {
        var presentation = AgentConversationPresentation()
        presentation.renameDraft = "ignored"
        #expect(presentation.modal == nil)

        presentation.present(.rename(draft: "Old"))
        presentation.renameDraft = "New"
        #expect(presentation.modal == .rename(draft: "New"))
        presentation.dismissRename()
        #expect(presentation.modal == nil)
        #expect(presentation.renameDraft.isEmpty)
    }

    @Test func lateDismissalOfAClosedModalKeepsItsSuccessor() {
        var presentation = AgentConversationPresentation()
        presentation.present(.modelPicker)
        presentation.dismiss(.deleteConfirmation)
        presentation.dismissRename()
        presentation.dismissNote()
        #expect(presentation.showsModelPicker)
    }

    /// Alert actions run before the alert dismisses, so the confirmation
    /// closes after `beginDeletion`; the in-flight delete must survive it.
    @Test func confirmedDeleteOutlivesItsConfirmationAndLaterModals() {
        var presentation = AgentConversationPresentation()
        presentation.present(.deleteConfirmation)
        presentation.beginDeletion()
        presentation.dismiss(.deleteConfirmation)
        #expect(presentation.modal == nil)
        #expect(presentation.suppressesMissingAgentFallback)

        // As on main, the menu stays usable while the request runs.
        presentation.present(.modelPicker)
        presentation.dismiss(.modelPicker)
        presentation.present(.deleteConfirmation)
        presentation.dismiss(.deleteConfirmation)
        #expect(presentation.suppressesMissingAgentFallback, "the agent:deleted fallback must not navigate twice")
    }

    @Test func failedDeleteRestoresTheMissingAgentFallback() {
        var presentation = AgentConversationPresentation()
        #expect(!presentation.suppressesMissingAgentFallback)
        presentation.beginDeletion()
        presentation.deletionFailed()
        #expect(!presentation.suppressesMissingAgentFallback)
    }

    @Test func noteSheetIsOneOfTheModals() {
        var presentation = AgentConversationPresentation()
        let note = NoteSheetInfo(noteId: "n", workspaceId: "w", noteTitle: "Spec")
        presentation.present(.note(note))
        #expect(presentation.note == note)
        presentation.present(.modelPicker)
        #expect(presentation.note == nil)
    }
}

struct QuestionWizardPresentationTests {
    @Test func openingOnePickerClosesTheOther() {
        var presentation = QuestionWizardPresentation()
        presentation.setPresenting(.photos, true)
        presentation.setPresenting(.files, true)
        #expect(presentation.isPresenting(.files))
        #expect(!presentation.isPresenting(.photos))
        presentation.setPresenting(.photos, false)
        #expect(presentation.isPresenting(.files), "a late false must not close the successor")
    }

    @Test func dismissIsReportedOnceAndNeverReset() {
        var presentation = QuestionWizardPresentation()
        presentation.setPresenting(.dismissConfirmation, true)
        let first = presentation.confirmDismiss(isSubmitting: false, isReadOnly: false)
        #expect(first)
        presentation.setPresenting(.dismissConfirmation, false)
        #expect(presentation.isDismissed)
        let second = presentation.confirmDismiss(isSubmitting: false, isReadOnly: false)
        #expect(!second)

        // As on main, the pickers stay usable after a dismissal.
        presentation.setPresenting(.photos, true)
        #expect(presentation.isPresenting(.photos))
        #expect(presentation.isDismissed)
    }

    @Test func dismissIsRefusedWhileSubmittingOrReadOnly() {
        var presentation = QuestionWizardPresentation()
        let whileSubmitting = presentation.confirmDismiss(isSubmitting: true, isReadOnly: false)
        let whileReadOnly = presentation.confirmDismiss(isSubmitting: false, isReadOnly: true)
        #expect(!whileSubmitting)
        #expect(!whileReadOnly)
        #expect(!presentation.isDismissed)
    }
}
