import Foundation
import ImageIO

/// Decoded frames and source timing for the bundled launch splash GIF.
struct SplashAnimation {
    static let resourceName = "IntentSplash"
    static let bundled: SplashAnimation? = {
        guard let url = Bundle.main.url(forResource: resourceName, withExtension: "gif") else {
            return nil
        }
        return SplashAnimation(url: url)
    }()

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