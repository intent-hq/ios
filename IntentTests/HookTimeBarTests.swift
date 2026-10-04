@testable import Intent
import Testing
import UIKit

@MainActor
struct HookTimeBarTests {
    @Test(arguments: [
        ("2026-10-03T12:00:30Z", 60_000, 0.5, 30.0),
        ("2026-10-03T12:00:30.500Z", 60_000, 30.5 / 60, 30.5),
        ("2026-10-03T12:00:30Z", 0, 0, 0),
        ("2026-10-03T12:00:30Z", -1, 0, 0),
        ("invalid", 60_000, 0, 0),
        ("2026-10-03T11:59:59Z", 60_000, 0, 0),
        ("2026-10-03T12:00:00Z", 60_000, 0, 0),
        ("2026-10-03T12:02:00Z", 60_000, 1, 60)
    ])
    func countdownClampsToCycle(next: String, delay: Int, fraction: Double, duration: Double) throws {
        let now = try #require(ISO8601DateFormatter.lenientDate(from: "2026-10-03T12:00:00Z"))
        let countdown = HookTimeBarView.countdown(nextRunAt: next, delayMs: delay, now: now)
        #expect(countdown.fraction == fraction)
        #expect(countdown.duration == duration)
    }

    @Test func attachedBarShrinksLinearlyToZeroWithoutChangingHeight() throws {
        let view = HookTimeBarView(frame: CGRect(x: 0, y: 0, width: 120, height: 1))
        let next = Date().addingTimeInterval(30).ISO8601Format()
        configure(view, next: next)
        let bar = try #require(view.layer.sublayers?.first)
        #expect(bar.animationKeys()?.isEmpty != false)

        let window = UIWindow()
        window.addSubview(view)
        view.layoutIfNeeded()
        let animation = try countdownAnimation(bar)
        let from = try #require(animation.fromValue as? Double)
        #expect(animation.keyPath == "transform.scale.x")
        #expect(animation.toValue as? Double == 0)
        #expect(animation.duration > 28 && animation.duration <= 30)
        #expect(abs(from - animation.duration / 60) < 0.000001)
        let timing = try #require(animation.timingFunction)
        var controlPoint: [Float] = [0, 0]
        timing.getControlPoint(at: 1, values: &controlPoint)
        #expect(controlPoint == [0, 0])
        timing.getControlPoint(at: 2, values: &controlPoint)
        #expect(controlPoint == [1, 1])
        #expect(animation.repeatCount == 0 && !animation.autoreverses)
        #expect(animation.isRemovedOnCompletion)
        #expect(bar.transform.m11 == 0 && bar.transform.m22 == 1)
        #expect(bar.bounds == view.bounds)
        #expect(bar.anchorPoint == CGPoint(x: 0, y: 0.5))
        #expect(bar.position == CGPoint(x: 0, y: 0.5))
        #expect(bar.backgroundColor == UIColor.gray.withAlphaComponent(0.5).cgColor)
        #expect(!view.isUserInteractionEnabled && !view.isAccessibilityElement)
    }

    @Test func resizingAndDirectionChangesKeepTheSameCountdown() throws {
        let window = UIWindow()
        let view = HookTimeBarView(frame: CGRect(x: 0, y: 0, width: 120, height: 1))
        let next = Date().addingTimeInterval(30).ISO8601Format()
        configure(view, next: next)
        window.addSubview(view)
        view.layoutIfNeeded()
        let bar = try #require(view.layer.sublayers?.first)
        let duration = try countdownAnimation(bar).duration

        configure(view, next: next, rightToLeft: true)
        view.bounds.size.width = 200
        view.layoutIfNeeded()
        #expect(bar.anchorPoint == CGPoint(x: 1, y: 0.5))
        #expect(bar.position == CGPoint(x: 200, y: 0.5))
        #expect(bar.bounds == view.bounds)
        #expect(try countdownAnimation(bar).duration == duration)
    }

    @Test func foregroundAndWindowReturnRebuildCountdownFromDeadline() throws {
        let window = UIWindow()
        let view = HookTimeBarView()
        let next = Date().addingTimeInterval(30).ISO8601Format()
        configure(view, next: next)
        window.addSubview(view)
        let bar = try #require(view.layer.sublayers?.first)
        let initial = try countdownAnimation(bar).duration

        configure(view, next: next, active: false)
        #expect(bar.animationKeys()?.isEmpty != false)
        #expect(bar.transform.m11 > 0 && bar.transform.m11 <= 0.5)
        configure(view, next: next)
        #expect(try countdownAnimation(bar).duration <= initial)
        #expect(bar.transform.m11 == 0)

        view.removeFromSuperview()
        #expect(bar.animationKeys()?.isEmpty != false)
        window.addSubview(view)
        #expect(try countdownAnimation(bar).duration <= initial)
    }

    @Test func newCycleRestartsButExpiredOrInvalidCycleStaysEmpty() throws {
        let window = UIWindow()
        let view = HookTimeBarView()
        window.addSubview(view)
        let bar = try #require(view.layer.sublayers?.first)
        configure(view, next: Date().addingTimeInterval(10).ISO8601Format())
        let initial = try countdownAnimation(bar).duration
        configure(view, next: Date().addingTimeInterval(30).ISO8601Format())
        #expect(try countdownAnimation(bar).duration > initial)

        for next in ["invalid", "2020-01-01T00:00:00Z"] {
            configure(view, next: next)
            #expect(bar.animationKeys()?.isEmpty != false)
            #expect(bar.transform.m11 == 0)
        }
    }

    private func configure(_ view: HookTimeBarView, next: String, rightToLeft: Bool = false, active: Bool = true) {
        view.configure(
            nextRunAt: next,
            delayMs: 60_000,
            color: UIColor.gray.withAlphaComponent(0.5),
            isRightToLeft: rightToLeft,
            isActive: active
        )
    }

    private func countdownAnimation(_ layer: CALayer) throws -> CABasicAnimation {
        let keys = try #require(layer.animationKeys())
        #expect(keys.count == 1)
        let key = try #require(keys.first)
        return try #require(layer.animation(forKey: key) as? CABasicAnimation)
    }
}
