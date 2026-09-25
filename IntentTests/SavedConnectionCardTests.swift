@testable import Intent
import SwiftUI
import Testing
import UIKit

@MainActor
struct SavedConnectionCardTests {
    @Test(arguments: [ColorScheme.light, .dark])
    func renderedCardUsesSavedPalette(scheme: ColorScheme) throws {
        let card = SavedConnectionCard(name: "Demo Mac", address: "demo.invalid:8080", isCurrentWindow: true)
            .frame(width: 354)
        let colors = try pixelColors(card, scheme: scheme)
        let expected = scheme == .light
            ? [[255, 255, 255], [8, 8, 8], [140, 140, 137], [111, 163, 86], [217, 217, 217]]
            : [[39, 39, 39], [240, 240, 235], [140, 140, 137], [111, 163, 86], [71, 71, 71]]
        for color in expected {
            #expect(pixelCount(color, in: colors) > 20, "Missing rendered Saved color: \(color), \(scheme)")
        }
        // Figma full-frame Outline/15% Black: light #00000026, dark #FFFFFF26.
        // The exact alpha/tint catches a warm divider that a tolerant pixel histogram could miss.
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        UIColor(Constants.Connections.divider(for: scheme)).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        #expect([red, green, blue] == Array(repeating: scheme == .light ? 0 : 1, count: 3))
        #expect(abs(alpha - 38 / 255) < 0.0001)
    }

    @Test(.serialized, arguments: [ColorScheme.light, .dark])
    func renderedManualEmptySheetUsesDesignPalette(scheme: ColorScheme) async throws {
        // Actual sheet, labels, fields and disabled button; no pairing action or live credentials.
        _ = TestKeychainStorage.installed
        let suiteName = "ManualPaletteTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let session = makeSession(defaults: defaults)
        let view = ManualTokenEntryView()
            .environment(session)
            .environment(session.makeCoordinator())
            .environment(\.colorScheme, scheme)
            .environment(\.dynamicTypeSize, .large)
            .frame(width: 402, height: 633)
        // ImageRenderer cannot flatten native text fields or lay out this sheet's scroll content.
        let colors = try await SyntheticBadgeHost.render(view, width: 402, height: 633) { hostView, _ in
            let renderer = UIGraphicsImageRenderer(bounds: hostView.bounds)
            var drawn = false
            let image = renderer.image { _ in
                drawn = hostView.drawHierarchy(in: hostView.bounds, afterScreenUpdates: true)
            }
            try #require(drawn)
            return try pixelColors(#require(image.cgImage))
        }
        // Independent full-frame references: light 3051:54152, dark 2989:19990.
        let expected = scheme == .light
            ? [
                [240, 240, 235], [8, 8, 8], [140, 140, 137], [82, 82, 80],
                [255, 255, 255], [186, 186, 183], [202, 202, 199]
            ]
            : [
                [22, 22, 22], [240, 240, 235], [140, 140, 137], [39, 39, 39],
                [82, 82, 80], [60, 60, 58]
            ]
        for color in expected {
            #expect(pixelCount(color, in: colors) > 20, "Missing rendered Manual color: \(color), \(scheme)")
        }
    }

    @Test(arguments: [ColorScheme.light, .dark], [false, true])
    func savedSheetOverridesPreserveDefaultColors(scheme: ColorScheme, useSavedColors: Bool) throws {
        let sheet = ConnectionSheet(
            initialHeight: 394,
            backgroundColor: useSavedColors ? Constants.Connections.background(for: scheme) : nil,
            closeForeground: useSavedColors ? Constants.Connections.foreground(for: scheme) : nil
        ) { EmptyView() }
            .frame(width: 402, height: 394)
        let colors = try pixelColors(sheet, scheme: scheme)
        let lightBackground = useSavedColors ? [240, 240, 235] : [255, 255, 255]
        let lightClose = useSavedColors ? [8, 8, 8] : [23, 23, 23]
        let background = scheme == .light ? lightBackground : [22, 22, 22]
        let close = scheme == .light ? lightClose : [240, 240, 235]
        #expect(pixelCount(background, in: colors) > 100_000)
        #expect(pixelCount(close, in: colors) > 20)
    }

    @Test func referenceCardsGrowForLongContentRatherThanClipping() throws {
        for current in [false, true] {
            let normal = try render(name: "Example Computer", address: "192.0.2.42:5180", current: current)
            #expect(normal == CGSize(width: 354, height: 96))
            let long = try render(
                name: "A saved connection with a much longer descriptive name that must wrap onto multiple lines",
                address: "host-with-a-long-name.example.invalid:5180, 192.0.2.43:5180",
                current: current
            )
            #expect(long.width == 354)
            #expect(long.height > normal.height)
        }
    }

    private func makeSession(defaults: UserDefaults) -> BackendSession {
        let connection = FakeConnectionManager()
        let store = WorkspaceStore(forTesting: true)
        let persistence = PersistenceManager(defaults: defaults, keychainStorage: InMemoryKeychainStorage())
        let fileLoader = WorkspaceFileImageLoader(connection: connection)
        return BackendSession(
            backendID: nil,
            connection: connection,
            workspaceStore: store,
            coordinatorFactory: { claim in
                AppCoordinator(
                    workspaceStore: store,
                    connection: connection,
                    persistence: persistence,
                    claimScreenRestoration: claim
                )
            },
            githubRepoStore: GitHubRepoStore(connectionManager: connection),
            creationOptionsStore: CreationOptionsStore(connectionManager: connection),
            prMonitorsStore: WorkspacePrMonitorsStore(connectionManager: connection),
            attachmentUploadService: AttachmentUploadService(connection: connection),
            workspaceFileImageLoader: fileLoader,
            attachmentImageLoader: AttachmentImageLoader(connection: connection, fileLoader: fileLoader),
            attentionCueCenter: WorkspaceAttentionCueCenter {}
        )
    }

    private func pixelColors<V: View>(_ view: V, scheme: ColorScheme) throws -> [[Int]] {
        let renderer = ImageRenderer(content: view
            .environment(\.colorScheme, scheme)
            .environment(\.dynamicTypeSize, .large))
        renderer.scale = 3
        let image = try #require(renderer.cgImage)
        return try pixelColors(image)
    }

    private func pixelColors(_ image: CGImage) throws -> [[Int]] {
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
        return stride(from: 0, to: bytes.count, by: 4).compactMap { index in
            guard bytes[index + 3] == 255 else { return nil }
            return [Int(bytes[index]), Int(bytes[index + 1]), Int(bytes[index + 2])]
        }
    }

    private func pixelCount(_ color: [Int], in pixels: [[Int]]) -> Int {
        pixels.filter { pixel in zip(pixel, color).allSatisfy { abs($0 - $1) <= 1 } }.count
    }

    private func render(name: String, address: String, current: Bool) throws -> CGSize {
        let renderer = ImageRenderer(content: SavedConnectionCard(name: name, address: address, isCurrentWindow: current)
            .frame(width: 354)
            .environment(\.colorScheme, .dark)
            .environment(\.dynamicTypeSize, .large))
        renderer.scale = 1
        let image = try #require(renderer.cgImage)
        return CGSize(width: image.width, height: image.height)
    }
}
