import Foundation
@testable import Intent
import Lottie
import SwiftUI
import Testing
import UIKit

@MainActor
@Suite(.serialized)
struct SplashAnimationTests {
    @Test func pulseStartsImmediatelyAndLoopsWithoutTheTwist() throws {
        let animation = try #require(SplashAnimation())
        for cycle in [0, 1, 4] {
            let start = Double(cycle) * animation.pulse.duration
            let first = animation.frame(at: start, animated: true, mode: .pulse)
            #expect(first.animation === animation.pulse)
            #expect(abs(first.frame - animation.pulse.startFrame) < 1e-6)

            let middle = animation.frame(at: start + animation.pulse.duration / 2, animated: true, mode: .pulse)
            #expect(middle.animation === animation.pulse)
            let expected = (animation.pulse.startFrame + animation.pulse.endFrame) / 2
            #expect(abs(middle.frame - expected) < 1e-6)
        }
    }

    @Test func defaultPlaybackPreservesTwistThenPulse() throws {
        let animation = try #require(SplashAnimation())
        let intro = animation.frame(at: animation.twist.duration / 2, animated: true)
        #expect(intro.animation === animation.twist)
        #expect(abs(intro.frame - (animation.twist.startFrame + animation.twist.endFrame) / 2) < 1e-6)

        for cycle in [0, 1, 4] {
            let elapsed = animation.twist.duration + Double(cycle) * animation.pulse.duration
            let sample = animation.frame(at: elapsed, animated: true)
            #expect(sample.animation === animation.pulse)
            #expect(abs(sample.frame - animation.pulse.startFrame) < 1e-6)
        }
    }

    @Test func twistLoopsAtItsOwnDurationWithoutTheEmptyOpeningFrame() throws {
        let animation = try #require(SplashAnimation())
        for cycle in [0, 1, 4] {
            let start = Double(cycle) * animation.twist.duration
            for (offset, expectedFrame) in [
                (0.0, animation.twist.startFrame + 1),
                (animation.twist.duration / 2, (animation.twist.startFrame + animation.twist.endFrame) / 2),
                (animation.twist.duration - 1 / animation.twist.framerate, animation.twist.endFrame - 1)
            ] {
                let sample = animation.frame(at: start + offset, animated: true, mode: .twistLoop)
                #expect(sample.animation === animation.twist)
                #expect(abs(sample.frame - expectedFrame) < 1e-6)
            }
        }
    }

    @Test(arguments: [-1.0, Double.infinity, Double.nan])
    func invalidTwistTimesSkipTheEmptyOpeningFrame(elapsed: TimeInterval) throws {
        let animation = try #require(SplashAnimation())
        let sample = animation.frame(at: elapsed, animated: true, mode: .twistLoop)
        #expect(sample.animation === animation.twist)
        #expect(sample.frame == animation.twist.startFrame + 1)
    }

    @Test func twistLoopSeamRendersVisibleArtwork() throws {
        let animation = try #require(SplashAnimation())
        let sample = animation.frame(at: animation.twist.duration, animated: true, mode: .twistLoop)
        let view = LottieAnimationView(animation: sample.animation, configuration: .init(renderingEngine: .mainThread))
        view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(bounds: view.bounds, format: format)
        for (frame, isVisible) in [(animation.twist.startFrame, false), (sample.frame, true)] {
            view.currentFrame = frame
            view.forceDisplayUpdate()
            let image = renderer.image { view.layer.render(in: $0.cgContext) }
            let pixels = try backgroundPixels(#require(image.cgImage))
            #expect(pixels.contains { $0[3] > 0 } == isVisible)
        }
    }

    @Test(arguments: [SplashAnimation.PlaybackMode.twistThenPulse, .pulse, .twistLoop])
    func disabledAnimationAlwaysShowsTheCompleteMark(mode: SplashAnimation.PlaybackMode) throws {
        let animation = try #require(SplashAnimation())
        for elapsed in [0, 0.5, 20] {
            let sample = animation.frame(at: elapsed, animated: false, mode: mode)
            #expect(sample.animation === animation.pulse)
            #expect(sample.frame == animation.pulse.startFrame)
        }
    }

    @Test(arguments: [-1.0, Double.infinity, Double.nan])
    func invalidPulseTimesStartAtTheCompleteMark(elapsed: TimeInterval) throws {
        let animation = try #require(SplashAnimation())
        let sample = animation.frame(at: elapsed, animated: true, mode: .pulse)
        #expect(sample.animation === animation.pulse)
        #expect(sample.frame == animation.pulse.startFrame)
    }

    @Test func pulseLoaderRestsWhenSceneIsInactive() async throws {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = try #require(SyntheticBadgeHostScene.resolve(in: scenes))
        let controller = UIHostingController(rootView: loader(scenePhase: .active))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 200, height: 200)
        window.rootViewController = controller
        defer { window.isHidden = true; window.rootViewController = nil; window.windowScene = nil }
        window.isHidden = false
        window.layoutIfNeeded()
        controller.view.layoutIfNeeded()
        try await waitUntil("pulse loader renders") { lottieView(in: controller.view) != nil }
        let rendered = try #require(lottieView(in: controller.view))
        let pulse = try #require(SplashAnimation()).pulse
        #expect(rendered.animation?.endFrame == pulse.endFrame)

        for phase in [ScenePhase.inactive, .background] {
            controller.rootView = loader(scenePhase: .active)
            try await waitUntil("active pulse advances") { rendered.currentFrame > pulse.startFrame }
            controller.rootView = loader(scenePhase: phase)
            try await waitUntil("paused pulse shows complete mark") { rendered.currentFrame == pulse.startFrame }
            try await expectNever("paused pulse advances", within: .milliseconds(150)) {
                rendered.currentFrame != pulse.startFrame || rendered.isAnimationPlaying
            }
        }
    }

    private func loader(scenePhase: ScenePhase) -> some View {
        IntentLoadingIndicator(size: 48, playbackMode: .pulse)
            .environment(\.scenePhase, scenePhase)
    }

    @Test func twistLoaderRestsWhenSceneIsInactive() async throws {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = try #require(SyntheticBadgeHostScene.resolve(in: scenes))
        let controller = UIHostingController(rootView: twistLoader())
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 200, height: 200)
        window.rootViewController = controller
        defer { window.isHidden = true; window.rootViewController = nil; window.windowScene = nil }
        window.isHidden = false
        window.layoutIfNeeded()
        controller.view.layoutIfNeeded()
        try await waitUntil("twist loader renders") { lottieView(in: controller.view) != nil }
        let rendered = try #require(lottieView(in: controller.view))
        let animation = try #require(SplashAnimation())

        for phase in [ScenePhase.inactive, .background] {
            controller.rootView = twistLoader()
            try await waitUntil("active twist advances") {
                rendered.animation?.endFrame == animation.twist.endFrame
                    && rendered.currentFrame > animation.twist.startFrame + 1
            }
            controller.rootView = twistLoader(scenePhase: phase)
            try await waitUntil("paused twist shows complete mark") {
                rendered.animation?.endFrame == animation.pulse.endFrame
                    && rendered.currentFrame == animation.pulse.startFrame
            }
            try await expectNever("paused twist advances", within: .milliseconds(150)) {
                rendered.currentFrame != animation.pulse.startFrame || rendered.isAnimationPlaying
            }
        }
    }

    private func twistLoader(scenePhase: ScenePhase = .active) -> some View {
        IntentLoadingIndicator(size: 48, playbackMode: .twistLoop)
            .environment(\.scenePhase, scenePhase)
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func sharedBackgroundPreservesArtworkEndpointsAndDarkFill(scheme: ColorScheme) throws {
        let renderer = ImageRenderer(content: SplashBackground()
            .frame(width: 4, height: 100)
            .environment(\.colorScheme, scheme))
        let image = try #require(renderer.cgImage)
        let pixels = try backgroundPixels(image)
        #expect(pixels.allSatisfy { $0[3] == 255 }, "The background must fill the proposed size")
        // Exported light artwork endpoints, or the opaque dark theme fill.
        let expected = scheme == .light ? [[243, 242, 241], [231, 245, 115]] : [[28, 28, 36]]
        for color in expected {
            #expect(pixels.contains { pixel in
                zip(pixel.prefix(3), color).allSatisfy { abs($0 - $1) <= 3 }
            })
        }
        if scheme == .dark {
            #expect(pixels.allSatisfy { $0 == pixels.first }, "Dark mode must be a uniform fill")
        }
    }

    private func backgroundPixels(_ image: CGImage) throws -> [[Int]] {
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(
                data: buffer.baseAddress,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: image.width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return stride(from: 0, to: bytes.count, by: 4).map { index in
            Array(bytes[index..<(index + 4)]).map(Int.init)
        }
    }

    private func lottieView(in view: UIView) -> LottieAnimationView? {
        if let animation = view as? LottieAnimationView { return animation }
        return view.subviews.lazy.compactMap { lottieView(in: $0) }.first
    }
}
