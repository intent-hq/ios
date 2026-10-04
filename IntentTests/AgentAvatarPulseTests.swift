@testable import Intent
import SwiftUI
import Testing
import UIKit

@MainActor
@Suite(.serialized)
struct AgentAvatarPulseTests {
    @Test func pulsePreservesDesignAndAnimatesOnlyStrokeColor() throws {
        let (window, view) = try makeRing()
        let ring = try ring(in: view)
        defer { view.removeFromSuperview(); window.isHidden = true }
        let animation = try pulse(on: ring)
        #expect(animation.keyPath == "strokeColor")
        #expect(animation.duration == 2.1)
        #expect(!animation.autoreverses)
        #expect(animation.repeatCount == .infinity)
        let keyframes = try #require(animation as? CAKeyframeAnimation)
        let keyTimes = try #require(keyframes.keyTimes)
        let times = keyTimes.map { $0.doubleValue * animation.duration }
        #expect(times.count == 5)
        for (actual, expected) in zip(times, [0, 1, 1.05, 2.05, 2.1]) {
            #expect(abs(actual - expected) < 1e-6)
        }
        #expect(keyframes.calculationMode == .linear)
        #expect(keyframes.timingFunctions == [
            CAMediaTimingFunction(name: .easeInEaseOut), CAMediaTimingFunction(name: .linear),
            CAMediaTimingFunction(name: .easeInEaseOut), CAMediaTimingFunction(name: .linear)
        ])
        #expect(ring.animationKeys()?.count == 1)
        #expect(ring.lineWidth == 1.5)
        #expect(ring.fillColor == nil)
        #expect(!view.isUserInteractionEnabled)
        try expectColors(on: ring, traits: view.traitCollection)
    }

    @Test func pulseReturnsAfterWindowRemovalAndForegroundActivation() throws {
        let (window, view) = try makeRing()
        let ring = try ring(in: view)
        defer { view.removeFromSuperview(); window.isHidden = true }
        view.removeFromSuperview()
        #expect(ring.animationKeys()?.isEmpty != false)
        window.addSubview(view)
        _ = try pulse(on: ring)

        ring.removeAllAnimations()
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        _ = try pulse(on: ring)
        view.removeFromSuperview()
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        #expect(ring.animationKeys()?.isEmpty != false)
    }

    @Test func resizeKeepsContinuousPathWithoutAnimatingGeometry() throws {
        let (window, view) = try makeRing()
        let ring = try ring(in: view)
        defer { view.removeFromSuperview(); window.isHidden = true }
        for size in [CGFloat(20), 36] {
            view.frame = CGRect(x: 50, y: 100, width: size, height: size)
            view.cornerRadius = size * 0.3
            view.layoutIfNeeded()
            let expected = RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                .path(in: CGRect(x: 0, y: 0, width: size, height: size)).cgPath
            #expect(ring.path == expected)
            #expect(ring.frame == view.bounds)
            #expect(ring.animationKeys()?.count == 1)
            #expect(try pulse(on: ring).keyPath == "strokeColor")
        }
    }

    @Test func appearanceChangeRefreshesBothPulseColors() throws {
        let (window, view) = try makeRing()
        let ring = try ring(in: view)
        defer { view.removeFromSuperview(); window.isHidden = true }
        for style in [UIUserInterfaceStyle.light, .dark, .light] {
            view.traitOverrides.userInterfaceStyle = style
            view.layoutIfNeeded()
            try expectColors(on: ring, traits: UITraitCollection(userInterfaceStyle: style))
        }
    }

    private func makeRing() throws -> (UIWindow, AgentAvatarPulse.PulseView) {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let view = AgentAvatarPulse.PulseView(cornerRadius: 6)
        view.frame = CGRect(x: 0, y: 0, width: 20, height: 20)
        window.addSubview(view)
        view.layoutIfNeeded()
        return (window, view)
    }

    private func ring(in view: UIView) throws -> CAShapeLayer {
        try #require(view.layer.sublayers?.compactMap { $0 as? CAShapeLayer }.first)
    }

    private func pulse(on ring: CAShapeLayer) throws -> CAPropertyAnimation {
        let key = try #require(ring.animationKeys()?.first)
        return try #require(ring.animation(forKey: key) as? CAPropertyAnimation)
    }

    private func expectColors(on ring: CAShapeLayer, traits: UITraitCollection) throws {
        let animation = try #require(pulse(on: ring) as? CAKeyframeAnimation)
        let weakColor = UIColor(.agentAvatarActiveStrokeWeak).resolvedColor(with: traits).cgColor
        let strongColor = UIColor(.agentAvatarActiveStrokeStrong).resolvedColor(with: traits).cgColor
        let colors = try #require(animation.values)
        #expect(colors.count == 5)
        for (actual, expected) in zip(colors, [weakColor, strongColor, strongColor, weakColor, weakColor]) {
            #expect(CFEqual(actual as CFTypeRef, expected))
        }
        #expect(ring.strokeColor == weakColor)
    }
}
