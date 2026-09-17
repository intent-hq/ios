@testable import Intent
import Testing
import UIKit

@Suite("Background task manager")
@MainActor
struct BackgroundTaskManagerTests {
    @Test func backgroundBeginsTask() {
        let application = FakeBackgroundTaskApplication()
        let manager = application.makeManager()

        manager.beginIfNeeded()

        #expect(application.beginCount == 1)
    }

    @Test func foregroundEndsTaskAndAllowsNextCycle() {
        let application = FakeBackgroundTaskApplication()
        let manager = application.makeManager()

        manager.beginIfNeeded()
        manager.endIfNeeded()
        manager.beginIfNeeded()
        manager.endIfNeeded()

        #expect(application.beginCount == 2)
        #expect(application.endedIdentifiers == [application.identifier, application.identifier])
    }

    @Test func expirationEndsTask() {
        let application = FakeBackgroundTaskApplication()
        let manager = application.makeManager()

        manager.beginIfNeeded()
        application.expirationHandler?()
        manager.endIfNeeded()

        #expect(application.endedIdentifiers == [application.identifier])
    }

    @Test func repeatedBackgroundDoesNotDoubleBegin() {
        let application = FakeBackgroundTaskApplication()
        let manager = application.makeManager()

        manager.beginIfNeeded()
        manager.beginIfNeeded()

        #expect(application.beginCount == 1)
    }
}

@MainActor
private final class FakeBackgroundTaskApplication {
    let identifier = UIBackgroundTaskIdentifier(rawValue: 1)
    private(set) var beginCount = 0
    private(set) var endedIdentifiers: [UIBackgroundTaskIdentifier] = []
    private(set) var expirationHandler: (@MainActor () -> Void)?

    func makeManager() -> BackgroundTaskManager {
        BackgroundTaskManager(
            beginTask: { [self] handler in
                beginCount += 1
                expirationHandler = handler
                return identifier
            },
            endTask: { [self] in endedIdentifiers.append($0) }
        )
    }
}
