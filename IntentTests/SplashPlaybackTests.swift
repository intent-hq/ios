import Foundation
@testable import Intent
import Lottie
import SwiftUI
import Testing
import UIKit

/// ios#247 / ios#256: splash playback samples one injectable monotonic clock
/// for both source-frame selection and pause/resume accounting. The decoded
/// compositions live only while a splash owner holds a lease on them.
struct SplashPlaybackTests {
    /// Stepped monotonic clock: nothing but `advance` moves it.
    private final class SteppedClock: SplashPlaybackClock {
        var now: TimeInterval

        init(now: TimeInterval = 100) {
            self.now = now
        }

        func advance(by seconds: TimeInterval) {
            now += seconds
        }
    }

    private final class Counter {
        var count = 0
    }

    private func bundledAnimation() throws -> SplashAnimation {
        try #require(
            SplashAnimation(),
            "The supplied twist and pulse JSON animations must decode from the app bundle"
        )
    }

    // MARK: - Frame selection under a stepped clock

    @Test func twistPlaysOnceThenPulseLoopsOnTheInjectedClock() throws {
        let animation = try bundledAnimation()
        let clock = SteppedClock(now: 0)
        var playback = SplashPlaybackState(clock: clock)
        playback.setRunning(true)

        // Source files: twist is 46 frames, pulse is 61, both at 30 fps.
        // Crossing the 1.2-second loading phase must not restart the intro.
        let samples: [(time: Double, expected: (animation: LottieAnimation, frame: Double))] = [
            (0, (animation.twist, 0)), (0.5, (animation.twist, 15)), (1.2, (animation.twist, 36)),
            (46.0 / 30, (animation.pulse, 0)), (61.0 / 30, (animation.pulse, 15)),
            (122.0 / 30, (animation.pulse, 15)), (183.0 / 30, (animation.pulse, 15))
        ]
        for sample in samples {
            clock.now = sample.time
            let rendered = animation.frame(at: playback.elapsedTime, animated: true)
            #expect(rendered.animation === sample.expected.animation)
            #expect(abs(rendered.frame - sample.expected.frame) < 0.0001)
        }
    }

    /// The clock-jump case: playback moves only when the injected monotonic
    /// clock moves. Real time passing between samples, or a wall-clock (NTP)
    /// adjustment, has no timestamp source to leak in through.
    @Test func elapsedTimeMovesOnlyWithTheInjectedClock() {
        let clock = SteppedClock()
        var playback = SplashPlaybackState(clock: clock)
        playback.setRunning(true)

        #expect(playback.elapsedTime == 0)
        #expect(playback.elapsedTime == 0)
        clock.advance(by: 1.5)
        #expect(playback.elapsedTime == 1.5)
        // The production clock is monotonic and never regresses; should an
        // injected one step backwards, the arithmetic clamps at zero rather
        // than producing a negative playback time.
        clock.advance(by: -10)
        #expect(playback.elapsedTime == 0)
        clock.advance(by: 10)
        #expect(playback.elapsedTime == 1.5)
    }

    // MARK: - Pause / resume

    @Test func pauseExcludesInactiveTimeAndResumeContinuesWithoutReset() {
        let clock = SteppedClock()
        var playback = SplashPlaybackState(clock: clock)
        #expect(!playback.isRunning)
        #expect(playback.elapsedTime == 0)

        playback.setRunning(true)
        clock.advance(by: 0.5)
        #expect(playback.isRunning)
        #expect(playback.elapsedTime == 0.5)

        playback.setRunning(false)
        clock.advance(by: 5)
        #expect(!playback.isRunning)
        #expect(playback.elapsedTime == 0.5)

        // Redundant transitions neither double-count nor restart.
        playback.setRunning(false)
        playback.setRunning(true)
        playback.setRunning(true)
        clock.advance(by: 0.25)
        #expect(playback.elapsedTime == 0.75)
    }

    // MARK: - Reduce Motion

    @Test func reduceMotionSelectsTheCompletePulseMarkAtAnyPlaybackTime() throws {
        let animation = try bundledAnimation()
        for elapsed in [0, 0.5, 1.2, 2, 100] {
            let rendered = animation.frame(at: elapsed, animated: false)
            #expect(rendered.animation === animation.pulse)
            #expect(rendered.frame == 0)
        }
    }

    @Test func reduceMotionAndInactiveScenesPausePlayback() {
        let animates = SplashArtView.shouldAnimate
        #expect(animates(.active, false, true))
        #expect(!animates(.active, true, true))
        #expect(!animates(.inactive, false, true))
        #expect(!animates(.background, false, true))
        #expect(!animates(.active, false, false))
    }

    // MARK: - Hosted logo layout

    /// Host UIKit as well as SwiftUI: ImageRenderer omits UIViewRepresentable
    /// content and cannot catch Lottie's intrinsic size escaping the frame.
    @MainActor
    @Test func launchLogoFitsTheFullCompositionInto100Points() async throws {
        let host = UIHostingController(rootView: SplashArtView()
            .environment(\.scenePhase, .inactive))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = host
        window.isHidden = false
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        host.view.layoutIfNeeded()
        let logo = try #require(findLogo(in: host.view))
        #expect(logo.bounds.size == CGSize(width: 100, height: 100))
        let viewport = logo.convert(logo.bounds, to: host.view)
        #expect(abs(viewport.midX - host.view.bounds.midX) < 0.5)
        #expect(abs(viewport.midY - host.view.bounds.midY) < 0.5)

        // A 100-point viewport must show all 256 source units, not crop a
        // full-sized composition behind a smaller frame.
        let composition = try #require(logo.convert(
            CGRect(x: 0, y: 0, width: 100, height: 100), toLayerAt: nil
        ))
        #expect(abs(composition.minX) < 0.5)
        #expect(abs(composition.minY) < 0.5)
        #expect(abs(composition.width - 256) < 0.5)
        #expect(abs(composition.height - 256) < 0.5)
    }

    @MainActor
    private func findLogo(in view: UIView) -> LottieAnimationView? {
        if let logo = view as? LottieAnimationView { return logo }
        return view.subviews.lazy.compactMap { findLogo(in: $0) }.first
    }

    // MARK: - Rendered launch background

    /// Samples the actual view, not the asset declaration: a missing catalog
    /// entry, aspect-fill crop, flat fallback, or dark variant must fail here.
    @MainActor
    @Test func launchGradientFillsPortraitAndLandscapeInEitherAppearance() throws {
        for scheme in [ColorScheme.light, .dark] {
            for size in [CGSize(width: 402, height: 874), CGSize(width: 874, height: 402)] {
                let renderer = ImageRenderer(content: SplashArtView()
                    .environment(\.colorScheme, scheme)
                    .frame(width: size.width, height: size.height))
                let image = try #require(renderer.cgImage)
                let width = image.width
                let height = image.height
                let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
                let context = try #require(CGContext(
                    data: nil,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width * 4,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ))
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
                // Independent design reference: off-white top, beige at 61.94%, lime bottom.
                let samples = [
                    (0, [243, 242, 241]), (Int(Double(height) * 0.619377), [235, 224, 208]),
                    (height - 1, [231, 245, 115])
                ]
                for (row, expected) in samples {
                    for column in [0, width - 1] {
                        let offset = (row * width + column) * 4
                        for channel in 0..<3 {
                            #expect(abs(Int(pixels[offset + channel]) - expected[channel]) <= 3)
                        }
                        #expect(pixels[offset + 3] == 255)
                    }
                }
            }
        }
    }

    // MARK: - Window appearance

    /// The real host's resolved appearance is what controls status-bar contrast.
    /// Another window must not change, and removing/replacing the splash subtree
    /// must restore both explicit Dark and the inherited System preference.
    @MainActor
    @Test func launchAppearanceIsWindowLocalAndClearsWhenSplashIsRemoved() async throws {
        let host = UIHostingController(rootView: appearanceProbe(showsSplash: true, preference: .dark))
        let other = UIHostingController(rootView: appearanceProbe(showsSplash: false, preference: .dark))
        let windows = [host, other].map { controller in
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
            window.rootViewController = controller
            window.isHidden = false
            return window
        }
        defer {
            for window in windows {
                window.isHidden = true
                window.rootViewController = nil
            }
        }
        try await waitForAppearance(.light, on: host)
        try await waitForAppearance(.dark, on: other)

        host.rootView = appearanceProbe(showsSplash: false, preference: .dark)
        try await waitForAppearance(.dark, on: host)
        host.rootView = appearanceProbe(showsSplash: true, preference: nil)
        try await waitForAppearance(.light, on: host)
        host.rootView = appearanceProbe(showsSplash: false, preference: nil)
        windows[0].overrideUserInterfaceStyle = .dark
        try await waitForAppearance(.dark, on: host)
        windows[0].overrideUserInterfaceStyle = .light
        try await waitForAppearance(.light, on: host)
        try await waitForAppearance(.dark, on: other)
    }

    private func appearanceProbe(showsSplash: Bool, preference: ColorScheme?) -> some View {
        ZStack {
            if showsSplash { SplashArtView() }
            Text("Connection status")
        }
        .modifier(LaunchAppearanceModifier(preferredColorScheme: preference))
    }

    @MainActor
    private func waitForAppearance(_ style: UIUserInterfaceStyle, on host: UIViewController) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while host.traitCollection.userInterfaceStyle != style, ContinuousClock.now < deadline {
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(host.traitCollection.userInterfaceStyle == style)
    }

    // MARK: - Composition lifetime

    @Test func compositionsAreDecodedOnceWhileAnyOwnerIsAliveAndReleasedAfterTheLast() throws {
        let loads = Counter()
        let store = SplashAnimationStore {
            loads.count += 1
            return SplashAnimation()
        }
        #expect(!store.isRetainingAnimations)

        var first = store.lease()
        var second = store.lease()
        weak var twist = first?.animation.twist
        weak var pulse = first?.animation.pulse
        #expect(first != nil)
        #expect(first === second)
        #expect(loads.count == 1)
        #expect(store.isRetainingAnimations)

        first = nil
        #expect(store.isRetainingAnimations)
        second = nil
        #expect(!store.isRetainingAnimations)
        #expect(twist == nil)
        #expect(pulse == nil)

        do {
            let third = store.lease()
            withExtendedLifetime(third) {
                #expect(loads.count == 2)
                #expect(store.isRetainingAnimations)
            }
        }
        #expect(!store.isRetainingAnimations)
    }

    @Test func sharedStoreServesTheBundledAnimation() throws {
        let lease = try #require(SplashAnimationStore.shared.lease())
        #expect(lease.animation.twist.size == CGSize(width: 256, height: 256))
        #expect(lease.animation.pulse.size == CGSize(width: 256, height: 256))
        #expect(lease.animation.twist.duration == 46.0 / 30)
        #expect(lease.animation.pulse.duration == 61.0 / 30)
    }
}
