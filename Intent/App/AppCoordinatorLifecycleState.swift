import Foundation

final class AppCoordinatorLifecycleState {
    enum Entry: Equatable {
        case routing(dataStamp: Date?)
        case routed(dataStamp: Date?)
        case entered
    }

    var entry = Entry.routing(dataStamp: nil)
    var hasEnteredRemoteUI: Bool { entry == .entered }
    var hasReturnedToSavedMachines = false

    func completeInitialRouting() {
        if case .routing(let dataStamp) = entry { entry = .routed(dataStamp: dataStamp) }
    }
}
