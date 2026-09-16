import Foundation
import ImageIO

/// Decoded frames and source timing for the bundled launch splash GIF.
struct SplashAnimation {
    static let resourceName = "IntentSplash"
    static var bundledURL: URL? {
        Bundle.main.url(forResource: resourceName, withExtension: "gif")
    }

    private static let fallbackFrameDuration: TimeInterval = 0.1

    let frames: [CGImage]
    let frameDurations: [TimeInterval]
    let duration: TimeInterval
    let sourceLoopCount: Int?

    var frameCount: Int { frames.count }
    var frameSize: CGSize? { frames.first.map { CGSize(width: $0.width, height: $0.height) } }
    var minimumFrameDuration: TimeInterval? { frameDurations.min() }

    init?(url: URL) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return nil }

        var images: [CGImage] = []
        var durations: [TimeInterval] = []
        images.reserveCapacity(count)
        durations.reserveCapacity(count)
        for index in 0..<count {
            guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else { return nil }
            images.append(image)
            durations.append(Self.frameDuration(in: source, at: index))
        }

        frames = images
        frameDurations = durations
        duration = durations.reduce(0, +)
        sourceLoopCount = Self.loopCount(in: source)
    }

    func frameIndex(at elapsedTime: TimeInterval, animated: Bool) -> Int {
        guard animated, frames.count > 1, duration > 0, elapsedTime.isFinite else { return 0 }
        let playbackTime = max(0, elapsedTime).truncatingRemainder(dividingBy: duration)
        var frameEndTime: TimeInterval = 0
        for index in frames.indices {
            frameEndTime += frameDurations[index]
            if playbackTime < frameEndTime { return index }
        }
        return frames.index(before: frames.endIndex)
    }

    func image(at elapsedTime: TimeInterval, animated: Bool) -> CGImage {
        frames[frameIndex(at: elapsedTime, animated: animated)]
    }

    private static func frameDuration(in source: CGImageSource, at index: Int) -> TimeInterval {
        guard
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil)
                as? [CFString: Any],
            let gif = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        else { return fallbackFrameDuration }

        let value = gif[kCGImagePropertyGIFUnclampedDelayTime] as? NSNumber
            ?? gif[kCGImagePropertyGIFDelayTime] as? NSNumber
        let duration = value?.doubleValue ?? fallbackFrameDuration
        return duration > 0 ? duration : fallbackFrameDuration
    }

    private static func loopCount(in source: CGImageSource) -> Int? {
        guard
            let properties = CGImageSourceCopyProperties(source, nil) as? [CFString: Any],
            let gif = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any],
            let count = gif[kCGImagePropertyGIFLoopCount] as? NSNumber
        else { return nil }
        return count.intValue
    }
}

/// Keeps one decoded `SplashAnimation` alive for as long as the owner holds it.
final class SplashAnimationLease {
    let animation: SplashAnimation

    fileprivate init(animation: SplashAnimation) {
        self.animation = animation
    }
}

/// Bounds the decoded frames' lifetime to their owners (ios#256): concurrent
/// owners share one decode, and the frames are released with the last lease
/// instead of living for the whole process.
final class SplashAnimationStore {
    static let shared = SplashAnimationStore {
        SplashAnimation.bundledURL.flatMap { SplashAnimation(url: $0) }
    }

    private let load: () -> SplashAnimation?
    private weak var current: SplashAnimationLease?

    init(load: @escaping () -> SplashAnimation?) {
        self.load = load
    }

    var isRetainingFrames: Bool { current != nil }

    func lease() -> SplashAnimationLease? {
        if let current { return current }
        guard let animation = load() else { return nil }
        let lease = SplashAnimationLease(animation: animation)
        current = lease
        return lease
    }
}