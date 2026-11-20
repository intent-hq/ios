import SwiftUI

enum WorkspaceChromePresentation: Equatable {
    case connections
    case createWorkspace
    case none
    case switcher

    mutating func createWorkspace(canCreate: Bool) {
        if canCreate {
            self = .createWorkspace
        } else if self == .switcher {
            self = .none
        }
    }

    mutating func dismissWorkspaceCreation() {
        if self == .createWorkspace { self = .none }
    }

    func isPresenting(_ presentation: Self) -> Bool { self == presentation }

    mutating func setPresenting(_ presentation: Self, _ presented: Bool) {
        if presented {
            self = presentation
        } else if self == presentation {
            self = .none
        }
    }
}

extension Binding where Value == WorkspaceChromePresentation {
    func presenting(_ presentation: WorkspaceChromePresentation) -> Binding<Bool> {
        Binding<Bool>(
            get: { wrappedValue.isPresenting(presentation) },
            set: { wrappedValue.setPresenting(presentation, $0) }
        )
    }
}
