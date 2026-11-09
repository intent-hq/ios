@testable import Intent
import SwiftUI
import Testing
import UIKit

@MainActor
@Suite(.serialized)
struct WorkspaceTranscriptDesignTests {
    // The 354pt fixture has a valid 265.5pt bubble: 2× represents both mirrored edges exactly.
    private let rasterScale: CGFloat = 2

    @Test func workspaceHeaderTracksWidthWithoutRecreatingItsContent() async throws {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = try #require(SyntheticBadgeHostScene.resolve(in: scenes))
        var appearances = 0
        let content = NavigationStack {
            Color.clear
                .onAppear { appearances += 1 }
                .navigationTitle("Workspace")
                .workspacePhoneNavigation(title: "Workspace", createdAt: nil, onBack: {}, actions: { Text("Actions") })
        }
        let controller = UIHostingController(rootView: content.environment(\.horizontalSizeClass, .regular))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 800)
        window.rootViewController = controller
        defer { window.isHidden = true; window.rootViewController = nil; window.windowScene = nil }
        window.isHidden = false
        window.layoutIfNeeded()
        try await waitUntil("workspace navigation is installed") {
            navigationController(in: controller) != nil && appearances == 1
        }
        let navigation = try #require(navigationController(in: controller))
        for sizeClass in [UserInterfaceSizeClass.regular, .compact, .regular, .compact] {
            controller.rootView = content.environment(\.horizontalSizeClass, sizeClass)
            try await waitUntil("navigation bar follows \(sizeClass) width") {
                navigation.isNavigationBarHidden == (sizeClass == .compact)
            }
            #expect(appearances == 1, "Changing the header must not recreate stateful workspace content")
            #expect(navigation.viewControllers.count == 1, "Resizing must not push or pop a destination")
        }
    }

    private func navigationController(in controller: UIViewController) -> UINavigationController? {
        if let navigation = controller as? UINavigationController { return navigation }
        return controller.children.lazy.compactMap { navigationController(in: $0) }.first
    }

    @Test(arguments: [CGFloat(272), CGFloat(354), CGFloat(620)])
    func bubbleAlignsToTrailingEdgeAndAccessibilityCanUseEntireWidth(width: CGFloat) async throws {
        let leftToRight = try bubblePixels(width: width, fullWidth: false, direction: .leftToRight)
        let rightToLeft = try bubblePixels(width: width, fullWidth: false, direction: .rightToLeft)
        let full = try bubblePixels(width: width, fullWidth: true, direction: .leftToRight)
        let fullRTL = try bubblePixels(width: width, fullWidth: true, direction: .rightToLeft)
        let leftGeometry = try await bubbleGeometry(width: width, fullWidth: false, direction: .leftToRight)
        let rightGeometry = try await bubbleGeometry(width: width, fullWidth: false, direction: .rightToLeft)
        #expect(leftGeometry.width == width * 0.75, "The fully flexible child must honor the approved width cap")
        #expect(rightGeometry.width == leftGeometry.width)
        #expect(leftGeometry.maxX == width)
        #expect(leftGeometry.minX > 0)
        #expect(rightGeometry.minX == 0)
        #expect(rightGeometry.maxX == width * 0.75)
        for direction in [LayoutDirection.leftToRight, .rightToLeft] {
            let fullGeometry = try await bubbleGeometry(width: width, fullWidth: true, direction: direction)
            #expect(fullGeometry.minX == 0)
            #expect(fullGeometry.maxX == width)
            #expect(fullGeometry.width == width)
        }
        let leading = try #require(leftToRight.first)
        #expect(leading > 0, "Ordinary bubbles must leave a leading gutter")
        #expect(leftToRight.last == Int(width * rasterScale) - 1)
        #expect(rightToLeft.first == 0)
        #expect(rightToLeft.count == leftToRight.count)
        #expect(leftToRight.count == Int(width * 0.75 * rasterScale))
        #expect(full.count == Int(width * rasterScale), "Accessibility layout must not retain the narrow width cap")
        #expect(fullRTL == full)
    }

    @Test(arguments: [CGFloat(272), CGFloat(354)])
    func realUserAndBlockerTextGrowRatherThanClip(width: CGFloat) {
        let text = "Please check the repository permissions before running the hosted benchmark. "
        let message = ConversationMessage(
            id: "layout-user",
            role: .user,
            contentBlocks: [ContentBlock(id: "text", type: .text, text: text)],
            timestamp: "2026-01-01T00:00:00Z"
        )
        let user = UserMessageView(
            message: message,
            workspaceId: "workspace",
            onNavigateToAgent: nil
        )
        .environment(makeSession())
        .environment(\.workspaceTranscriptDesign, true)
        let blocker = AttentionNoticeView(notice: AttentionNotice(kind: .blockerReport, reason: text))
            .environment(\.workspaceTranscriptDesign, true)
        let standardUser = size(user, width: width, category: .large)
        let accessibleUser = size(user, width: width, category: .accessibility5)
        let standardBlocker = size(blocker, width: width, category: .large)
        let accessibleBlocker = size(blocker, width: width, category: .accessibility5)
        #expect(accessibleUser.width <= width)
        #expect(accessibleBlocker.width <= width)
        #expect(accessibleUser.height > standardUser.height)
        #expect(accessibleBlocker.height > standardBlocker.height)
        let longer = AttentionNoticeView(notice: AttentionNotice(kind: .blockerReport, reason: String(repeating: text, count: 3)))
            .environment(\.workspaceTranscriptDesign, true)
        #expect(size(longer, width: width, category: .accessibility5).height > accessibleBlocker.height)
    }

    private func size(_ view: some View, width: CGFloat, category: DynamicTypeSize) -> CGSize {
        let controller = UIHostingController(rootView: view.environment(\.dynamicTypeSize, category))
        return controller.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
    }

    private func makeSession() -> BackendSession {
        let connection = FakeConnectionManager()
        let fileLoader = WorkspaceFileImageLoader(connection: connection)
        return BackendSession(
            backendID: BackendID(UUID()),
            connection: connection,
            workspaceStore: WorkspaceStore(forTesting: true),
            coordinatorFactory: { _ in fatalError("Rendering this user message must not create a coordinator") },
            githubRepoStore: GitHubRepoStore(connectionManager: connection),
            creationOptionsStore: CreationOptionsStore(connectionManager: connection),
            prMonitorsStore: WorkspacePrMonitorsStore(connectionManager: connection),
            attachmentUploadService: AttachmentUploadService(connection: connection),
            workspaceFileImageLoader: fileLoader,
            attachmentImageLoader: AttachmentImageLoader(connection: connection, fileLoader: fileLoader),
            attentionCueCenter: WorkspaceAttentionCueCenter {}
        )
    }

    private func bubbleGeometry(width: CGFloat, fullWidth: Bool, direction: LayoutDirection) async throws -> CGRect {
        var frame: CGRect?
        let view = WorkspaceUserBubbleLayout(usesFullWidth: fullWidth, layoutDirection: direction) {
            Color.red.frame(height: 40)
                .onGeometryChange(for: CGRect.self) { proxy in
                    proxy.frame(in: .named("bubbleContainer"))
                } action: { frame = $0 }
        }
        .frame(width: width)
        .coordinateSpace(name: "bubbleContainer")
        return try await SyntheticBadgeHost.render(view, width: width, height: 40, safeAreaRegions: []) { _, _ in
            try #require(frame)
        }
    }

    private func bubblePixels(width: CGFloat, fullWidth: Bool, direction: LayoutDirection) throws -> [Int] {
        let renderer = ImageRenderer(content: WorkspaceUserBubbleLayout(usesFullWidth: fullWidth, layoutDirection: direction) {
            // Semantic Color.red is not pure RGB red and can exceed the pixel probe's green threshold.
            Color(.sRGB, red: 1, green: 0, blue: 0, opacity: 1).frame(height: 40)
        }.frame(width: width).background(.white))
        renderer.scale = rasterScale
        let bitmap = try #require(renderer.cgImage)
        var pixels = [UInt8](repeating: 0, count: bitmap.width * bitmap.height * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try #require(CGContext(
                data: bytes.baseAddress,
                width: bitmap.width,
                height: bitmap.height,
                bitsPerComponent: 8,
                bytesPerRow: bitmap.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(bitmap, in: CGRect(x: 0, y: 0, width: bitmap.width, height: bitmap.height))
        }
        let row = bitmap.height / 2
        return (0..<bitmap.width).filter { column in
            let offset = (row * bitmap.width + column) * 4
            return pixels[offset] > 200 && pixels[offset + 1] < 50 && pixels[offset + 2] < 50
        }
    }
}
