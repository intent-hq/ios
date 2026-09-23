@testable import Intent
import SwiftUI
import Testing

/// Consumer rendering checks: the desktop half-fill, ring accessibility
/// styling, and component footprints survive moving their layout tokens.
@MainActor
struct ComponentVisualLayoutTests {
    @Test(arguments: [24.0, 48.0], [false, true])
    func taskStatusKeepsItsRightHalfFillAtEveryScale(size: Double, increasedContrast: Bool) throws {
        let contrast: ColorSchemeContrast = increasedContrast ? .increased : .standard
        // ImageRenderer needs the SDK's writable backing key; colorSchemeContrast is read-only.
        let icon = TaskStatusIconView(status: .inProgress, size: CGFloat(size))
            .environment(\._colorSchemeContrast, contrast)
        let leftToRight = try pixels(icon.environment(\.layoutDirection, .leftToRight))
        let rightToLeft = try pixels(icon.environment(\.layoutDirection, .rightToLeft))
        #expect(leftToRight.width == Int(size))
        #expect(leftToRight.height == Int(size))
        #expect(leftToRight.bytes == rightToLeft.bytes, "Desktop half-fill must not mirror in RTL")
        let quarter = Int(size / 4)
        let center = Int(size / 2)
        #expect(leftToRight.alpha(x: center - quarter / 2, y: center) == 0)
        #expect(leftToRight.alpha(x: center + quarter / 2, y: center) == 255)
    }

    @Test func progressRingPreservesContrastAndNonColorCues() throws {
        let ring = TaskProgressRingView(stats: TaskStats(total: 4, completed: 1, inProgress: 2), size: 56)
        let standard = try pixels(ring.environment(\._colorSchemeContrast, .standard))
        let increased = try pixels(ring.environment(\._colorSchemeContrast, .increased))
        let differentiated = try pixels(ring.environment(\.accessibilityDifferentiateWithoutColor, true))
        let rightToLeft = try pixels(ring.environment(\.layoutDirection, .rightToLeft))
        #expect(standard.width == 56 && standard.height == 56)
        #expect(increased.width == standard.width && increased.height == standard.height)
        #expect(increased.alphaTotal > standard.alphaTotal, "Increased contrast must thicken the ring")
        #expect(differentiated.bytes != standard.bytes, "Non-color mode must dash the in-progress arc")
        #expect(rightToLeft.bytes == standard.bytes, "Progress arcs must keep their clockwise geometry")
    }

    @Test(arguments: [DynamicTypeSize.large, .accessibility5])
    func defaultComponentFootprintsRemainStable(textSize: DynamicTypeSize) throws {
        let status = try pixels(TaskStatusIconView(status: .complete).environment(\.dynamicTypeSize, textSize))
        let ring = try pixels(
            TaskProgressRingView(stats: TaskStats(total: 1, completed: 1, inProgress: 0))
                .environment(\.dynamicTypeSize, textSize)
        )
        let agent = try pixels(AgentAvatarView(agentId: "layout-test").environment(\.dynamicTypeSize, textSize))
        let owner = try pixels(RepoOwnerAvatarView(owner: nil).environment(\.dynamicTypeSize, textSize))
        #expect(status.width == 16 && status.height == 16)
        #expect(ring.width == 14 && ring.height == 14)
        #expect(agent.width == 20 && agent.height == 20)
        #expect(owner.width == 28 && owner.height == 28)
    }

    private struct Pixels {
        let width: Int
        let height: Int
        let bytes: [UInt8]

        func alpha(x: Int, y: Int) -> UInt8 {
            bytes[(y * width + x) * 4 + 3]
        }

        var alphaTotal: Int {
            stride(from: 3, to: bytes.count, by: 4).reduce(0) { $0 + Int(bytes[$1]) }
        }
    }

    private func pixels(_ content: some View) throws -> Pixels {
        let renderer = ImageRenderer(content: content.environment(\.colorScheme, .light))
        renderer.scale = 1
        let image = try #require(renderer.cgImage)
        let context = try #require(CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: image.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = try #require(context.data)
        let bytes = Array(UnsafeBufferPointer(
            start: data.assumingMemoryBound(to: UInt8.self),
            count: image.width * image.height * 4
        ))
        return Pixels(width: image.width, height: image.height, bytes: bytes)
    }
}
