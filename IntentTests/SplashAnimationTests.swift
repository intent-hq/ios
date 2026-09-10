import Foundation
import SwiftUI
import Testing
import UIKit
@testable import Intent

struct SplashAnimationTests {
    private func animation() throws -> SplashAnimation {
        try #require(SplashAnimation.bundled, "IntentSplash.gif is missing from the app bundle")
    }

    @Test func bundledGifHasExpectedSourceMetadata() throws {
        let animation = try animation()

        #expect(animation.frameCount == 51)
        #expect(animation.frameSize == CGSize(width: 256, height: 256))
        #expect(abs(animation.duration - 2.04) < 0.001)
        #expect(animation.sourceLoopCount == 0)
        #expect(animation.frames.allSatisfy { $0.alphaInfo == .noneSkipLast })
    }

    @Test func frameSelectionUsesSourceTimingAndLoops() throws {
        let animation = try animation()

        #expect(animation.frameIndex(at: 0, animated: true) == 0)
        #expect(animation.frameIndex(at: 0.039, animated: true) == 0)
        #expect(animation.frameIndex(at: 0.04, animated: true) == 1)
        #expect(animation.frameIndex(at: 2.039, animated: true) == 50)
        #expect(animation.frameIndex(at: animation.duration, animated: true) == 0)
        #expect(animation.frameIndex(at: animation.duration + 0.041, animated: true) == 1)
    }

    @Test func reducedMotionAlwaysSelectsStaticFirstFrame() throws {
        let animation = try animation()

        #expect(animation.frameIndex(at: 0, animated: false) == 0)
        #expect(animation.frameIndex(at: 1.5, animated: false) == 0)
        #expect(animation.frameIndex(at: 200, animated: false) == 0)
    }

    @Test func playbackExcludesInactiveTimeAndResumesWithoutReset() {
        var playback = SplashPlaybackState()
        let start = Date(timeIntervalSinceReferenceDate: 10)

        playback.setRunning(true, at: start)
        #expect(playback.elapsedTime(at: start.addingTimeInterval(0.5)) == 0.5)

        playback.setRunning(false, at: start.addingTimeInterval(0.75))
        #expect(playback.elapsedTime(at: start.addingTimeInterval(5)) == 0.75)

        playback.setRunning(true, at: start.addingTimeInterval(10))
        #expect(playback.elapsedTime(at: start.addingTimeInterval(10.25)) == 1)
    }
}

@MainActor
struct SplashFrameRenderingTests {
    @Test func logoUsesApprovedMaximumAndShrinksInConstrainedLayouts() throws {
        #expect(Constants.Splash.maximumLogoDimension == 80)

        let image = try #require(SplashAnimation.bundled?.frames[25])
        let fullSizePixels = try rgbaPixels(in: renderedImage(
            image: image, scheme: .light, side: 160))
        let constrainedPixels = try rgbaPixels(in: renderedImage(
            image: image, scheme: .light, side: 40))

        let fullSizeBounds = try #require(nonBackgroundBounds(
            in: fullSizePixels, width: 160, background: rgba(Theme.background(for: .light))))
        let constrainedBounds = try #require(nonBackgroundBounds(
            in: constrainedPixels, width: 40, background: rgba(Theme.background(for: .light))))
        #expect(fullSizeBounds.width <= 80 && fullSizeBounds.height <= 80)
        #expect(fullSizeBounds.minX >= 40 && fullSizeBounds.maxX <= 120)
        #expect(fullSizeBounds.minY >= 40 && fullSizeBounds.maxY <= 120)
        #expect(constrainedBounds.width <= 40 && constrainedBounds.height <= 40)
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func renderedFrameUsesThemeColorsWithoutImageRectangle(_ scheme: ColorScheme) throws {
        let image = try #require(SplashAnimation.bundled?.frames[25])
        let rendered = try renderedImage(image: image, scheme: scheme, side: 160)
        let pixels = try rgbaPixels(in: rendered)
        let background = rgba(Theme.background(for: scheme))
        let foreground = rgba(Theme.foreground(for: scheme))

        #expect(pixels.filter { $0 == background }.count > 20_000)
        let includesForeground = pixels.contains { $0.isApproximately(foreground) }
        let includesAntialiasedEdge = pixels.contains {
            $0 != background && !$0.isApproximately(foreground)
        }
        #expect(includesForeground)
        #expect(includesAntialiasedEdge)
        #expect(pixel(in: pixels, x: 40, y: 40, width: 160) == background)
        #expect(pixel(in: pixels, x: 119, y: 119, width: 160) == background)
        if scheme == .dark {
            #expect(!pixels.contains(RGBA(red: 255, green: 255, blue: 255, alpha: 255)))
        }
    }

    private func renderedImage(
        image: CGImage, scheme: ColorScheme, side: CGFloat
    ) throws -> UIImage {
        let renderer = ImageRenderer(content: ZStack {
            Theme.background(for: scheme)
            SplashFrameView(image: image, colorScheme: scheme)
        }.frame(width: side, height: side))
        renderer.scale = 1
        return try #require(renderer.uiImage)
    }

    private func rgbaPixels(in image: UIImage) throws -> [RGBA] {
        let cgImage = try #require(image.cgImage)
        var bytes = [UInt8](repeating: 0, count: cgImage.width * cgImage.height * 4)
        let context = try #require(CGContext(
            data: &bytes, width: cgImage.width, height: cgImage.height,
            bitsPerComponent: 8, bytesPerRow: cgImage.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        return stride(from: 0, to: bytes.count, by: 4).map {
            RGBA(red: bytes[$0], green: bytes[$0 + 1], blue: bytes[$0 + 2], alpha: bytes[$0 + 3])
        }
    }

    private func rgba(_ color: Color) -> RGBA {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return RGBA(red: byte(red), green: byte(green), blue: byte(blue), alpha: byte(alpha))
    }

    private func byte(_ value: CGFloat) -> UInt8 { UInt8((value * 255).rounded()) }

    private func pixel(in pixels: [RGBA], x: Int, y: Int, width: Int) -> RGBA {
        pixels[y * width + x]
    }

    private func nonBackgroundBounds(
        in pixels: [RGBA], width: Int, background: RGBA
    ) -> CGRect? {
        let points = pixels.indices.compactMap { index -> CGPoint? in
            guard pixels[index] != background else { return nil }
            return CGPoint(x: index % width, y: index / width)
        }
        guard let first = points.first else { return nil }
        return points.dropFirst().reduce(CGRect(origin: first, size: .zero)) {
            $0.union(CGRect(origin: $1, size: .zero))
        }
    }

    private struct RGBA: Equatable {
        let red: UInt8
        let green: UInt8
        let blue: UInt8
        let alpha: UInt8

        func isApproximately(_ other: RGBA, tolerance: Int = 2) -> Bool {
            abs(Int(red) - Int(other.red)) <= tolerance
                && abs(Int(green) - Int(other.green)) <= tolerance
                && abs(Int(blue) - Int(other.blue)) <= tolerance
                && abs(Int(alpha) - Int(other.alpha)) <= tolerance
        }
    }
}