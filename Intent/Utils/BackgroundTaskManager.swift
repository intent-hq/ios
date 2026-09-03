import UIKit

@MainActor
final class BackgroundTaskManager {
    typealias BeginTask = (@escaping @MainActor () -> Void) -> UIBackgroundTaskIdentifier
    typealias EndTask = (UIBackgroundTaskIdentifier) -> Void

    private let beginTask: BeginTask
    private let endTask: EndTask
    private var taskIdentifier: UIBackgroundTaskIdentifier = .invalid

    init(
        beginTask: @escaping BeginTask = { expirationHandler in
            UIApplication.shared.beginBackgroundTask(
                withName: "Agent completion notifications",
                expirationHandler: expirationHandler
            )
        },
        endTask: @escaping EndTask = { identifier in
            UIApplication.shared.endBackgroundTask(identifier)
        }
    ) {
        self.beginTask = beginTask
        self.endTask = endTask
    }

    func beginIfNeeded() {
        guard taskIdentifier == .invalid else { return }
        taskIdentifier = beginTask { [weak self] in
            self?.endIfNeeded()
        }
    }

    func endIfNeeded() {
        guard taskIdentifier != .invalid else { return }
        let identifier = taskIdentifier
        taskIdentifier = .invalid
        endTask(identifier)
    }
}
