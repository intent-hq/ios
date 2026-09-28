import Testing
import UIKit

@MainActor
enum SyntheticBadgeHostScene {
    static func preferredIndex(in states: [UIScene.ActivationState]) -> Int? {
        states.firstIndex(of: .foregroundActive)
            ?? states.firstIndex(of: .foregroundInactive)
    }

    static func resolve(in scenes: [UIWindowScene]) -> UIWindowScene? {
        preferredIndex(in: scenes.map(\.activationState)).map { scenes[$0] }
    }

    static func description(of scenes: [UIWindowScene]) -> String {
        let states = scenes.map { "\($0.session.persistentIdentifier):state=\($0.activationState.rawValue),windows=\($0.windows.count)" }
        return "applicationState=\(UIApplication.shared.applicationState.rawValue) connectedWindowScenes=\(states)"
    }
}

extension SyntheticBadgeHostTests {
    @Test func sceneSelectionAcceptsInactiveForeground() {
        #expect(SyntheticBadgeHostScene.preferredIndex(in: [.foregroundInactive]) == 0)
        #expect(SyntheticBadgeHostScene.preferredIndex(in: [.background, .foregroundInactive, .unattached]) == 1)
    }

    @Test func activeSceneIsPreferredOverInactiveConnectedScenes() {
        #expect(SyntheticBadgeHostScene.preferredIndex(in: [.foregroundInactive, .foregroundActive]) == 1)
        #expect(SyntheticBadgeHostScene.preferredIndex(in: [.foregroundActive, .foregroundInactive]) == 0)
    }

    @Test(arguments: [
        [UIScene.ActivationState](), [.unattached], [.background], [.background, .unattached]
    ])
    func absentOrOffscreenScenesCannotSupplyTheRenderedHost(states: [UIScene.ActivationState]) {
        #expect(SyntheticBadgeHostScene.preferredIndex(in: states) == nil)
    }
}
