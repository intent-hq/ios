import Foundation

enum ConnectionScreen: Equatable {
    case connecting(startedByLaunch: Bool)
    case other
    case pairing(showsSavedConnections: Bool)

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
