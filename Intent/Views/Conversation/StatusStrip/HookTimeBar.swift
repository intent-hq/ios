import SwiftUI
import UIKit

/// Core Animation owns the continuous shrink, avoiding per-frame SwiftUI work.
/// The parent keeps `.id(nextRunAt)` so each new hook cycle gets a fresh bar.
struct HookTimeBar: UIViewRepresentable {
    let nextRunAt: String
    let delayMs: Int
    let color: Color

    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.scenePhase) private var scenePhase

    func makeUIView(context _: Context) -> HookTimeBarView {
        HookTimeBarView()
    }

    func updateUIView(_ view: HookTimeBarView, context _: Context) {
        view.configure(
            nextRunAt: nextRunAt,
            delayMs: delayMs,
            color: UIColor(color),
            isRightToLeft: layoutDirection == .rightToLeft,
            isActive: scenePhase == .active
        )
    }
}

final class HookTimeBarView: UIView {
    private let bar = CALayer()
    private var nextRunAt = ""
    private var delayMs = 0
    private var isActive = false
    private var isRightToLeft = false
    private static let animationKey = "countdown"
    private static let millisecondsPerSecond = 1000.0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        layer.addSublayer(bar)
        bar.transform = CATransform3DMakeScale(0, 1, 1)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Retains the original clamping behavior for invalid or out-of-cycle dates.
    static func countdown(nextRunAt: String, delayMs: Int, now: Date) -> (fraction: Double, duration: TimeInterval) {
        guard delayMs > 0, let next = ISO8601DateFormatter.lenientDate(from: nextRunAt) else {
            return (0, 0)
        }
        let total = Double(delayMs) / Self.millisecondsPerSecond
        let remaining = max(0, min(total, next.timeIntervalSince(now)))
        return (remaining / total, remaining)
    }

    func configure(nextRunAt: String, delayMs: Int, color: UIColor, isRightToLeft: Bool, isActive: Bool) {
        let needsRestart = self.nextRunAt != nextRunAt || self.delayMs != delayMs || self.isActive != isActive
        self.nextRunAt = nextRunAt
        self.delayMs = delayMs
        self.isActive = isActive
        self.isRightToLeft = isRightToLeft
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bar.backgroundColor = color.cgColor
        CATransaction.commit()
        setNeedsLayout()
        if needsRestart { synchronize() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bar.anchorPoint = CGPoint(x: isRightToLeft ? 1 : 0, y: 0.5)
        bar.bounds = CGRect(origin: .zero, size: bounds.size)
        bar.position = CGPoint(x: isRightToLeft ? bounds.maxX : bounds.minX, y: bounds.midY)
        CATransaction.commit()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        synchronize()
    }

    private func synchronize() {
        bar.removeAnimation(forKey: Self.animationKey)
        let countdown = Self.countdown(nextRunAt: nextRunAt, delayMs: delayMs, now: Date())
        let animates = window != nil && isActive && countdown.duration > 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // The final model value remains zero after the animation is removed.
        bar.transform = CATransform3DMakeScale(animates ? 0 : countdown.fraction, 1, 1)
        if animates {
            let animation = CABasicAnimation(keyPath: "transform.scale.x")
            animation.fromValue = countdown.fraction
            animation.toValue = 0
            animation.duration = countdown.duration
            animation.timingFunction = CAMediaTimingFunction(name: .linear)
            bar.add(animation, forKey: Self.animationKey)
        }
        CATransaction.commit()
    }
}
