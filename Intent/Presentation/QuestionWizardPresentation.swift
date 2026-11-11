import SwiftUI

/// The question wizard's photo picker, file importer and dismiss
/// confirmation, plus whether the user dismissed the questions.
struct QuestionWizardPresentation: Equatable {
    /// At most one of these is open.
    enum Modal: Equatable {
        case photos
        case files
        case dismissConfirmation
    }

    private(set) var modal: Modal?
    /// Set once the user confirms Dismiss and never cleared: the host mounts a
    /// new wizard for a new question set. Pickers stay usable afterwards, so
    /// this is tracked next to `modal` rather than as one of its cases.
    private(set) var isDismissed = false

    func isPresenting(_ modal: Modal) -> Bool { self.modal == modal }

    mutating func setPresenting(_ modal: Modal, _ presented: Bool) {
        if presented {
            self.modal = modal
        } else if self.modal == modal {
            self.modal = nil
        }
    }

    /// The user confirmed Dismiss. Returns true when the caller should report
    /// the dismissal: only once, and not while answers are being submitted or
    /// the connection is read-only.
    mutating func confirmDismiss(isSubmitting: Bool, isReadOnly: Bool) -> Bool {
        guard !isDismissed, !isSubmitting, !isReadOnly else { return false }
        isDismissed = true
        return true
    }
}

extension Binding where Value == QuestionWizardPresentation {
    func presenting(_ modal: QuestionWizardPresentation.Modal) -> Binding<Bool> {
        Binding<Bool>(
            get: { wrappedValue.isPresenting(modal) },
            set: { wrappedValue.setPresenting(modal, $0) }
        )
    }
}
