import SwiftUI

extension ConversationTranscriptScrollState {
    struct DemoRecoveryResize {
        let token: ConversationTranscriptRecoveryLifecycle.RecoveryToken
        let pageUp: ConversationTranscriptScrollPolicy.ViewportGeometry
        var resizedHeight: CGFloat?
        var beforeFollowBack: ConversationTranscriptScrollPolicy.ViewportGeometry?
        var followBackObserved = false
        var ownedAtFollowBack = false
    }
}

extension ConversationTranscriptView {
    private var demoRecoveryResizeEnabled: Bool {
        #if DEBUG
        DemoMode.isEnabled && LaunchOptions.current.contains("--demo-hooks-row-during-recovery")
        #else
        false
        #endif
    }

    #if DEBUG
    func releaseHooksRowDuringDemoRecovery(geometry: ConversationTranscriptScrollPolicy.ViewportGeometry) {
        guard demoRecoveryResizeEnabled, scrollState.demoRecoveryResize == nil,
              !isUserInteracting, case .recovery(let token) = lifecycle.owner,
              case .triggerFile(let triggerFile) = DemoFixtures.longConversationHookListGate
        else { return }
        scrollState.demoRecoveryResize = .init(token: token, pageUp: geometry)
        do {
            try Data().write(to: triggerFile)
            AppLog.userInterface.debug("[SCROLL] Demo: released hooks during recovery \(token), pageUp=\(geometry)")
        } catch {
            AppLog.userInterface.debug("[SCROLL] Demo: could not release hooks during recovery")
        }
    }
    #endif

    func recordDemoRecoveryResize(from oldHeight: CGFloat, to newHeight: CGFloat) {
        guard demoRecoveryResizeEnabled, var receipt = scrollState.demoRecoveryResize,
              !receipt.followBackObserved, newHeight < oldHeight,
              lifecycle.owner == .recovery(receipt.token)
        else { return }
        receipt.resizedHeight = newHeight
        scrollState.demoRecoveryResize = receipt
        AppLog.userInterface.debug("[SCROLL] Demo: footer resized during recovery \(receipt.token): \(oldHeight)->\(newHeight)")
    }

    func recordDemoRecoveryResizeFollowBack(_ event: Lifecycle.Event) {
        guard demoRecoveryResizeEnabled, case .recoveryPagedUp(let token, _) = event,
              var receipt = scrollState.demoRecoveryResize, receipt.token == token,
              !receipt.followBackObserved
        else { return }
        receipt.followBackObserved = true
        receipt.beforeFollowBack = scrollMomentumProxy.restingGeometry
        receipt.ownedAtFollowBack = lifecycle.owner == .recovery(token)
        scrollState.demoRecoveryResize = receipt
        AppLog.userInterface.debug(
            "[SCROLL] Demo: footer overlap before follow-back: \(demoRecoveryResizeReport)"
        )
    }

    var demoRecoveryResizeReport: String {
        guard demoRecoveryResizeEnabled else { return "" }
        guard let receipt = scrollState.demoRecoveryResize else { return " resizeProbe=pending" }
        var report = " resizeProbe=observed pageUpOffset=\(receipt.pageUp.contentOffsetY)"
            + " pageUpHeight=\(receipt.pageUp.containerHeight) pageUpDistance=\(receipt.pageUp.distanceToBottom)"
            + " resizeOverlap=\(receipt.resizedHeight != nil) followBackOwned=\(receipt.ownedAtFollowBack)"
        if let height = receipt.resizedHeight { report += " resizedHeight=\(height)" }
        if let geometry = receipt.beforeFollowBack {
            report += " preFollowOffset=\(geometry.contentOffsetY) preFollowHeight=\(geometry.containerHeight)"
                + " preFollowDistance=\(geometry.distanceToBottom)"
        }
        return report
    }
}
