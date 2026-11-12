import Foundation

/// The fields only the connection screens read. `.loading` and `.connecting`
/// share one splash, so both use `.connecting`; every other screen is `.other`.
/// `AppCoordinator.currentScreen` keeps the case in step with the screen.
enum ConnectionScreen: Equatable {
    /// `startedByLaunch`: launch/restoration auto-connect, which uses the launch
    /// artwork and hides Connecting's Back action until startup needs it.
    case connecting(startedByLaunch: Bool)
    case other
    /// Connect to…: whether to offer the other saved connections (for example
    /// after logging off one connection while others are still saved).
    case pairing(showsSavedConnections: Bool)

    /// The value kept when `currentScreen` changes: entering a connection
    /// screen without an explicit value starts with its flag off.
    func kept(on screen: AppScreen) -> Self {
        switch (screen, self) {
        case (.loading, .connecting), (.connecting, .connecting), (.pairing, .pairing):
            return self
        case (.loading, _), (.connecting, _):
            return .connecting(startedByLaunch: false)
        case (.pairing, _):
            return .pairing(showsSavedConnections: false)
        default:
            return .other
        }
    }
}

/// The connection-loss overlay after the user entered the remote UI. `.lost`
/// stays until the transport reconnects; `.recovering` then waits for workspace
/// data (or the overlay timeout) before clearing, so the UI never flashes blank.
enum ConnectionLoss {
    case lost
    case none
    case recovering(observationID: UUID, timeout: Task<Void, Never>)
}

extension ConnectionLoss {
    var isLost: Bool {
        if case .none = self { return false }
        return true
    }
}
