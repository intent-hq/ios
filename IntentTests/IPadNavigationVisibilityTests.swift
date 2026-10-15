@testable import Intent
import Testing
import UIKit

@MainActor
struct IPadNavigationVisibilityTests {
    @Test func hiddenPaneDisablesOnlyItsNavigationController() {
        let fixture = Fixture(isInteractive: false)
        let sibling = UINavigationController(rootViewController: UIViewController())
        let container = UIViewController()
        container.addChild(fixture.navigation)
        container.addChild(sibling)

        #expect(fixture.navigation.view.accessibilityElementsHidden)
        #expect(!fixture.navigation.view.isUserInteractionEnabled)
        #expect(!sibling.view.accessibilityElementsHidden)
        #expect(sibling.view.isUserInteractionEnabled)
        #expect(container.view.isUserInteractionEnabled)

        fixture.marker.isInteractive = true
        #expect(!fixture.navigation.view.accessibilityElementsHidden)
        #expect(fixture.navigation.view.isUserInteractionEnabled)
    }

    @Test func retainedRootControlsPushedDestinationsWithoutReplacingThem() {
        let fixture = Fixture()
        let destination = UIViewController()
        fixture.navigation.setViewControllers([fixture.root, destination], animated: false)

        fixture.marker.isInteractive = false
        #expect(fixture.navigation.view.accessibilityElementsHidden)
        #expect(!fixture.navigation.view.isUserInteractionEnabled)
        fixture.marker.isInteractive = true
        #expect(!fixture.navigation.view.accessibilityElementsHidden)
        #expect(fixture.navigation.view.isUserInteractionEnabled)
        #expect(fixture.navigation.topViewController === destination)
        #expect(fixture.navigation.viewControllers.first === fixture.root)
    }

    @Test(arguments: [false, true], [false, true])
    func teardownRestoresOriginalFlags(hidden: Bool, interactive: Bool) {
        let fixture = Fixture(originalHidden: hidden, originalInteractive: interactive)
        fixture.marker.isInteractive = false
        fixture.marker.restoreVisibility()
        fixture.marker.restoreVisibility()
        #expect(fixture.navigation.view.accessibilityElementsHidden == hidden)
        #expect(fixture.navigation.view.isUserInteractionEnabled == interactive)
    }

    @Test func detachingHiddenMarkerRestoresItsFormerController() {
        let fixture = Fixture(isInteractive: false)
        fixture.marker.willMove(toParent: nil)
        fixture.marker.removeFromParent()
        #expect(!fixture.navigation.view.accessibilityElementsHidden)
        #expect(fixture.navigation.view.isUserInteractionEnabled)

        let next = UINavigationController(rootViewController: UIViewController())
        let root = next.viewControllers[0]
        root.addChild(fixture.marker)
        fixture.marker.didMove(toParent: root)
        #expect(next.view.accessibilityElementsHidden)
        #expect(!next.view.isUserInteractionEnabled)
        #expect(fixture.navigation.view.isUserInteractionEnabled)
    }

    @Test func missingNavigationControllerLeavesEnclosingViewAlone() {
        let parent = UIViewController()
        let marker = IPadNavigationVisibilityBridge.Controller()
        marker.isInteractive = false
        parent.addChild(marker)
        marker.didMove(toParent: parent)
        marker.viewDidLayoutSubviews()
        #expect(!parent.view.accessibilityElementsHidden)
        #expect(parent.view.isUserInteractionEnabled)
    }

    @Test func layoutFindsNavigationAfterInitialParentAttachment() {
        let root = UIViewController()
        let marker = IPadNavigationVisibilityBridge.Controller()
        marker.isInteractive = false
        root.addChild(marker)
        marker.didMove(toParent: root)
        let navigation = UINavigationController(rootViewController: root)

        marker.viewDidLayoutSubviews()

        #expect(navigation.view.accessibilityElementsHidden)
        #expect(!navigation.view.isUserInteractionEnabled)
        marker.isInteractive = true
        #expect(!navigation.view.accessibilityElementsHidden)
        #expect(navigation.view.isUserInteractionEnabled)
    }

    private final class Fixture {
        let root = UIViewController()
        let navigation: UINavigationController
        let marker = IPadNavigationVisibilityBridge.Controller()

        init(isInteractive: Bool = true, originalHidden: Bool = false, originalInteractive: Bool = true) {
            navigation = UINavigationController(rootViewController: root)
            navigation.view.accessibilityElementsHidden = originalHidden
            navigation.view.isUserInteractionEnabled = originalInteractive
            let wrapper = UIViewController()
            root.addChild(wrapper)
            wrapper.didMove(toParent: root)
            marker.isInteractive = isInteractive
            wrapper.addChild(marker)
            marker.didMove(toParent: wrapper)
        }
    }
}
