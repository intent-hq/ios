import Foundation
@testable import Intent
import SwiftUI
import Testing
import UIKit

@MainActor
struct WorkspaceStatusImageViewTests {
    private typealias Layout = WorkspaceStatusImageLayout

    private func workspace(statusImageAssetId: String?) -> Workspace {
        Workspace(
            id: "ws-1",
            title: "W",
            branch: nil,
            baseRef: nil,
            status: nil,
            activity: nil,
            displayStatus: nil,
            lastActivity: nil,
            updatedAt: nil,
            repositoryOwner: nil,
            repositoryName: nil,
            prStatus: nil,
            prNumber: nil,
            diffSummaryTotalFiles: nil,
            taskStatsTotal: nil,
            taskStatsCompleted: nil,
            taskStatsInProgress: nil,
            agentSummaryCount: nil,
            agentSummaryAgents: [],
            statusImageAssetId: statusImageAssetId
        )
    }

    @Test func normalizedAssetIdDropsBlankAndMissingValues() {
        #expect(Layout.normalizedAssetId(nil) == nil)
        #expect(Layout.normalizedAssetId("") == nil)
        #expect(Layout.normalizedAssetId("  \n") == nil)
        #expect(Layout.normalizedAssetId("m1-abc.png") == "m1-abc.png")
        #expect(Layout.normalizedAssetId(" m1-abc.png ") == "m1-abc.png")
    }

    @Test func unsetWorkspaceRendersNoImage() {
        #expect(Layout.assetId(for: nil) == nil)
        #expect(Layout.assetId(for: workspace(statusImageAssetId: nil)) == nil)
        #expect(Layout.assetId(for: workspace(statusImageAssetId: "m1-abc.png")) == "m1-abc.png")
    }

    @Test func loadKeyChangesWhenTheAssetIsReplacedOrRetried() {
        let base = Layout.loadKey(workspaceId: "ws-1", assetId: "a.png", attempt: 0)
        #expect(base == Layout.loadKey(workspaceId: "ws-1", assetId: "a.png", attempt: 0))
        #expect(base != Layout.loadKey(workspaceId: "ws-1", assetId: "b.png", attempt: 0))
        #expect(base != Layout.loadKey(workspaceId: "ws-2", assetId: "a.png", attempt: 0))
        #expect(base != Layout.loadKey(workspaceId: "ws-1", assetId: "a.png", attempt: 1))
    }

    @Test func detailImageHasAccessibilityIdentifierAndLabel() {
        #expect(Layout.accessibilityIdentifier == "workspaceDetail.statusImage")
        #expect(Layout.accessibilityLabel == "Workspace status image")
    }

    // MARK: - Hosted: a superseded fetch must not overwrite its replacement

    @Test(
        .enabled(
            Comment(
                rawValue:
                    "SwiftUI publishes its accessibility tree only when accessibility is enabled "
                    + "for the process (scripts/xcodebuild.sh enables it on the simulator)"
            )
        ) {
            await SyntheticBadgeHost.publishesAccessibilityTree()
        }
    )
    func supersededLoadDoesNotOverwriteReplacement() async throws {
        let fake = FakeConnectionManager()
        fake.pendingMethods.insert("note.readAsset")
        let loader = WorkspaceFileImageLoader(connection: fake)
        let host = HostedImage(loader: loader)
        defer { host.tearDown() }

        host.show(assetId: "asset-A.png")
        try await Self.waitUntil("A requested") { Self.requestedAssets(fake) == ["asset-A.png"] }

        host.show(assetId: "asset-B.png")
        try await Self.waitUntil("B requested") {
            Self.requestedAssets(fake) == ["asset-A.png", "asset-B.png"]
        }

        let png = Self.pngBase64()
        fake.resolvePending(
            "note.readAsset",
            with: [
                "assetId": "asset-A.png", "mimeType": "image/png", "data": png, "sizeKb": 1
            ]
        )
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(!host.showsImage, "the superseded A fetch populated the view")

        fake.resolvePending(
            "note.readAsset",
            with: [
                "assetId": "asset-B.png", "mimeType": "image/png", "data": png, "sizeKb": 1
            ]
        )
        try await Self.waitUntil("B rendered") { host.showsImage }
    }

    private static func requestedAssets(_ fake: FakeConnectionManager) -> [String] {
        fake.requestLog
            .filter { $0.method == "note.readAsset" }
            .compactMap { $0.params["asset"] as? String }
    }

    private static func pngBase64() -> String {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8))
        return renderer.pngData { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        .base64EncodedString()
    }

    private static func waitUntil(
        _ what: String,
        timeout: TimeInterval = 5,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline {
                Issue.record("timed out waiting for \(what)")
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    @MainActor
    private final class HostedImage {
        private let loader: WorkspaceFileImageLoader
        private var controller: UIHostingController<AnyView>?
        private var window: UIWindow?

        init(loader: WorkspaceFileImageLoader) {
            self.loader = loader
            let controller = UIHostingController(rootView: AnyView(EmptyView()))
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 300))
            controller.view.frame = window.bounds
            controller.beginAppearanceTransition(true, animated: false)
            window.addSubview(controller.view)
            window.isHidden = false
            controller.endAppearanceTransition()
            self.controller = controller
            self.window = window
        }

        func show(assetId: String) {
            controller?.rootView = AnyView(
                WorkspaceStatusImageView(
                    workspaceId: "ws-1",
                    assetId: assetId,
                    loader: loader
                )
                .frame(width: 390, height: 300, alignment: .topLeading)
            )
            controller?.view.layoutIfNeeded()
        }

        var showsImage: Bool {
            guard let view = controller?.view else { return false }
            view.layoutIfNeeded()
            return SyntheticBadgeHost.accessibilityElements(in: view).contains { element in
                SyntheticBadgeHost.accessibilityIdentifier(of: element)
                    == WorkspaceStatusImageLayout.accessibilityIdentifier
            }
        }

        func tearDown() {
            guard let controller, let window else { return }
            controller.beginAppearanceTransition(false, animated: false)
            controller.view.removeFromSuperview()
            window.isHidden = true
            controller.endAppearanceTransition()
            self.controller = nil
            self.window = nil
        }
    }
}
