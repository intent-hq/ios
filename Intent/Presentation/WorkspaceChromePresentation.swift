import SwiftUI

/// What the workspace list chrome shows over the list: the connection switcher
/// drawer, the Create Workspace sheet or the Connections sheet. At most one is
/// open. `RootView` (regular width) and `WorkspaceListView` (compact width)
/// each hold one value and change it only through these methods.
enum WorkspaceChromePresentation: Equatable {
    case connections
    case createWorkspace
    case none
    /// The connection switcher drawer.
    case switcher

    /// Create Workspace always closes the switcher; it opens the sheet only
    /// when the coordinator allows creation. Otherwise any open sheet stays.
    mutating func createWorkspace(canCreate: Bool) {
        if canCreate {
            self = .createWorkspace
        } else if self == .switcher {
            self = .none
        }
    }

    /// The coordinator finished or cancelled creation elsewhere.
    mutating func dismissWorkspaceCreation() {
        if self == .createWorkspace { self = .none }
    }

    func isPresenting(_ presentation: Self) -> Bool { self == presentation }

    /// Binding setter for one presentation. Clearing applies only while that
    /// presentation is the open one, so a late `false` from a closing sheet
    /// or drawer cannot close its successor.
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
