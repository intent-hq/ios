import SwiftUI

struct QuestionWizardPresentation: Equatable {
    enum Modal: Equatable {
        case photos
        case files
        case dismissConfirmation
    }

    private(set) var modal: Modal?
    private(set) var isDismissed = false

    func isPresenting(_ modal: Modal) -> Bool { self.modal == modal }

    mutating func setPresenting(_ modal: Modal, _ presented: Bool) {
        if presented {
            self.modal = modal
        } else if self.modal == modal {
            self.modal = nil
        }
    }

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
