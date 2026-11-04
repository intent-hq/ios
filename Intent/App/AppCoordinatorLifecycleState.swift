import Foundation

final class AppCoordinatorLifecycleState {
    /// Progress toward usable remote UI. `dataStamp` is workspace data that
    /// predates the flow, so it cannot prove this flow fetched anything.
    enum Entry: Equatable {
        case routing(dataStamp: Date?)
        case routed(dataStamp: Date?)
        /// A connection loss may now present the overlay.
        case entered
    }

    var entry = Entry.routing(dataStamp: nil)
    var hasEnteredRemoteUI: Bool { entry == .entered }
    /// Orthogonal to `entry`: late callbacks after returning home are ignored.
    var hasReturnedToSavedMachines = false

    func completeInitialRouting() {
        if case .routing(let dataStamp) = entry { entry = .routed(dataStamp: dataStamp) }
    }
}
