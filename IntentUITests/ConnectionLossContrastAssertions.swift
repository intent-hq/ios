import XCTest

/// Checks real source-to-overlay appearance propagation, not just the subtitle's label.
/// Run the owning Home test in light/dark and actual Reduce Transparency modes.
extension ConnectionLossUITests {
    private enum Contrast {
        static let minimumRatio = 4.5
        static let minimumWhiteLuminance = 0.9
        static let approvedGrayLuminance = 0.262
        static let grayTolerance = 0.02
        // WCAG sRGB relative-luminance and contrast coefficients.
        static let luminanceOffset = 0.05
        static let redWeight = 0.2126
        static let greenWeight = 0.7152
        static let blueWeight = 0.0722
        static let linearThreshold = 0.04045
        static let linearDivisor = 12.92
        static let gammaOffset = 0.055
        static let gammaDivisor = 1.055
        static let gammaExponent = 2.4
        static let channelMaximum = 255.0
        static let bytesPerPixel = 4
        static let bitsPerChannel = 8
    }

    @MainActor
    func assertConnectionLossSubtitleContrast(in app: XCUIApplication, sourceImage: UIImage) throws {
        let subtitle = app.staticTexts["connection-loss.message"]
        let sourcePixels = try subtitleLuminances(in: sourceImage, region: subtitle.frame)
        let overlayPixels = try subtitleLuminances(in: app.screenshot().image, region: subtitle.frame)
        let sourceIsLight = sourcePixels[sourcePixels.count / 2] > 0.5
        // The median is the local backdrop; solid glyph interiors are the brightest pixels.
        let backdrop = overlayPixels[overlayPixels.count / 2]
        let foreground = try XCTUnwrap(overlayPixels.last)
        let contrast = (foreground + Contrast.luminanceOffset) / (backdrop + Contrast.luminanceOffset)
        XCTAssertGreaterThanOrEqual(contrast, Contrast.minimumRatio, "The rendered subtitle must remain readable over its source page")
        if sourceIsLight {
            XCTAssertGreaterThan(foreground, Contrast.minimumWhiteLuminance, "A light source requires the approved white subtitle")
        } else {
            XCTAssertEqual(foreground, Contrast.approvedGrayLuminance, accuracy: Contrast.grayTolerance, "Preserve the approved gray subtitle over a dark source")
        }
        let evidence = XCTAttachment(string: "Source: \(sourceIsLight ? "light" : "dark"); subtitle contrast: \(contrast):1")
        evidence.name = "connection-loss-subtitle-contrast"
        evidence.lifetime = .keepAlways
        XCTContext.runActivity(named: "Rendered subtitle contrast") { $0.add(evidence) }
    }

    private func subtitleLuminances(in image: UIImage, region: CGRect) throws -> [Double] {
        let fullImage = try XCTUnwrap(image.cgImage)
        let scale = CGFloat(fullImage.width) / image.size.width
        let pixelRegion = region.applying(CGAffineTransform(scaleX: scale, y: scale)).integral
        let crop = try XCTUnwrap(fullImage.cropping(to: pixelRegion))
        var bytes = [UInt8](repeating: 0, count: crop.width * crop.height * Contrast.bytesPerPixel)
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: &bytes,
            width: crop.width,
            height: crop.height,
            bitsPerComponent: Contrast.bitsPerChannel,
            bytesPerRow: crop.width * Contrast.bytesPerPixel,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        let luminances = stride(from: 0, to: bytes.count, by: Contrast.bytesPerPixel).map { index in
            let red = linearChannel(bytes[index])
            let green = linearChannel(bytes[index + 1])
            let blue = linearChannel(bytes[index + 2])
            return Contrast.redWeight * red + Contrast.greenWeight * green + Contrast.blueWeight * blue
        }
        return luminances.sorted()
    }

    private func linearChannel(_ byte: UInt8) -> Double {
        let value = Double(byte) / Contrast.channelMaximum
        return value <= Contrast.linearThreshold
            ? value / Contrast.linearDivisor
            : pow((value + Contrast.gammaOffset) / Contrast.gammaDivisor, Contrast.gammaExponent)
    }
}
