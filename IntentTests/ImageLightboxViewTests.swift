import CoreGraphics
import Testing
@testable import Intent

struct ImageLightboxViewTests {
    @Test func zeroViewportSafelyCollapsesOffset() {
        let offset = ImageLightboxLayout.clampedOffset(
            CGSize(width: 80, height: 60),
            imageSize: CGSize(width: 400, height: 300),
            scale: 2,
            minimumScale: 1,
            in: .zero
        )

        #expect(offset == .zero)
    }

    @Test func fittedImageOffsetIsClampedToScaledEdges() {
        let offset = ImageLightboxLayout.clampedOffset(
            CGSize(width: 250, height: 100),
            imageSize: CGSize(width: 100, height: 100),
            scale: 2,
            minimumScale: 1,
            in: CGSize(width: 300, height: 600)
        )

        #expect(offset == CGSize(width: 150, height: 0))
    }

    @Test func unzoomedImageCannotPan() {
        let offset = ImageLightboxLayout.clampedOffset(
            CGSize(width: 20, height: -20),
            imageSize: CGSize(width: 100, height: 100),
            scale: 1,
            minimumScale: 1,
            in: CGSize(width: 300, height: 600)
        )

        #expect(offset == .zero)
    }
}