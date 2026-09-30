@testable import Intent
import SwiftUI
import Testing
import UIKit

@MainActor
struct NavigationPopObserverTests {
    @Test func startsBeforePoppedDestinationLosesItsParent() {
        let fixture = Fixture()
        fixture.navigation.transitionStack = [fixture.root]
        #expect(fixture.destination.parent === fixture.navigation)
        #expect(!fixture.destination.isMovingFromParent)

        fixture.observer.viewWillDisappear(true)

        #expect(fixture.isPopping)
    }

    @Test func pushingAnotherScreenDoesNotStartPop() {
        let fixture = Fixture()
        fixture.navigation.transitionStack = [fixture.root, fixture.destination, UIViewController()]

        fixture.observer.viewWillDisappear(true)

        #expect(!fixture.isPopping)
    }

    @Test func cancelledPopRestoresComposerAvoidance() {
        let fixture = Fixture()
        fixture.navigation.transitionStack = [fixture.root]
        fixture.observer.viewWillDisappear(true)
        #expect(fixture.isPopping)

        fixture.navigation.transitionStack = [fixture.root, fixture.destination]
        fixture.observer.viewWillAppear(true)

        #expect(!fixture.isPopping)
    }

    private final class Fixture {
        let root = UIViewController()
        let destination = UIViewController()
        let navigation = TransitionNavigationController()
        let observer = NavigationPopObserver.Controller()
        var isPopping = false

        init() {
            let wrapper = UIViewController()
            destination.addChild(wrapper)
            wrapper.didMove(toParent: destination)
            wrapper.addChild(observer)
            observer.didMove(toParent: wrapper)
            navigation.viewControllers = [root, destination]
            observer.isPopping = Binding(get: { [weak self] in self?.isPopping ?? false }, set: { [weak self] in self?.isPopping = $0 })
        }
    }

    private final class TransitionNavigationController: UINavigationController {
        var transitionStack: [UIViewController] = []

        override var viewControllers: [UIViewController] {
            get { transitionStack.isEmpty ? super.viewControllers : transitionStack }
            set { super.viewControllers = newValue }
        }
    }
}
