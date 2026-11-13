import CoreGraphics
import Foundation
@testable import Intent
import SwiftUI
import Testing
import UIKit

struct WorkspaceDetailViewTests {
    @Test(.enabled("The host must publish accessible controls") {
        await SyntheticBadgeHost.publishesAccessibilityTree()
    }, arguments: [false, true])
    @MainActor func resourceBrowserShortcutReusesOrCreates(hasBrowser: Bool) async throws {
        let session = makePinnedSession(connection: FakeConnectionManager())
        if hasBrowser { _ = try session.browserStore.create(workspaceId: "workspace", url: "localhost:3000") }
        let shortcuts = WorkspaceResourceShortcuts(workspaceId: "workspace")
            .modifier(NativeBrowserPresenter())
            .environment(session)
            .environment(\.scenePhase, .active)
        try await SyntheticBadgeHost.render(shortcuts, width: 386, height: 600) { host, window in
            let browser = try #require(SyntheticBadgeHost.accessibilityElements(in: host).first { element in
                SyntheticBadgeHost.accessibilityIdentifier(of: element) == "workspace.shortcut.browser"
            })
            #expect(browser.accessibilityActivate())
            try await waitUntil("the browser shortcut presents its destination") {
                window.rootViewController?.presentedViewController != nil
            }
            let destination = try #require(window.rootViewController?.presentedViewController)
            let expectedLabel = hasBrowser ? "Browser URL" : "Browser address"
            try await waitUntil("the shortcut opens the existing browser or the creation form") {
                SyntheticBadgeHost.accessibilityElements(in: destination.view).contains { element in
                    element.accessibilityLabel == expectedLabel
                }
            }
            #expect(session.browserStore.browsers(workspaceId: "workspace").count == (hasBrowser ? 1 : 0))
            await destination.dismiss(animated: false)
        }
    }

    @MainActor
    @Test(arguments: [WorkspaceTab.agents, .context, .changes, .unsupportedPersistedValue(42)])
    func savedTabIsSelectedBeforeWorkspaceAppears(tab: WorkspaceTab) throws {
        let suiteName = "WorkspaceDetailViewTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let persistence = PersistenceManager(defaults: defaults)
        persistence.saveWorkspaceTab(workspaceId: "saved-workspace", tab: tab.persistedValue)
        let session = makePinnedSession(connection: FakeConnectionManager())

        let saved = WorkspaceDetailView(workspaceId: "saved-workspace", session: session, storesCache: WorkspaceDetailStoresCache(), persistence: persistence)
        let unsaved = WorkspaceDetailView(workspaceId: "new-workspace", session: session, storesCache: WorkspaceDetailStoresCache(), persistence: persistence)

        #expect(saved.currentTab == tab)
        #expect(unsaved.currentTab == .agents)
        #expect(persistence.loadWorkspaceTab(workspaceId: "saved-workspace") == tab.persistedValue)
        #expect(persistence.loadWorkspaceTab(workspaceId: "new-workspace") == nil)
    }

    @Test func delegatedAgentCountUsesLegibleSingularAndPluralLabels() {
        #expect(AgentGroupSummary.delegatedTitle(count: 1) == "1 delegated agent")
        #expect(AgentGroupSummary.delegatedTitle(count: 34) == "34 delegated agents")
    }

    // MARK: - Session store routing (multi-window state split)

    /// A backend-bound session composed over a fake backend connection; the
    /// coordinator factory is never invoked by these tests.
    @MainActor
    func makePinnedSession(connection: FakeConnectionManager) -> BackendSession {
        let fileLoader = WorkspaceFileImageLoader(connection: connection)
        return BackendSession(
            backendID: BackendID(UUID()),
            connection: connection,
            workspaceStore: WorkspaceStore(forTesting: true),
            coordinatorFactory: { _ in fatalError("coordinator is not built in these tests") },
            githubRepoStore: GitHubRepoStore(connectionManager: connection),
            creationOptionsStore: CreationOptionsStore(connectionManager: connection),
            prMonitorsStore: WorkspacePrMonitorsStore(connectionManager: connection),
            attachmentUploadService: AttachmentUploadService(connection: connection),
            workspaceFileImageLoader: fileLoader,
            attachmentImageLoader: AttachmentImageLoader(
                connection: connection,
                fileLoader: fileLoader
            ),
            attentionCueCenter: WorkspaceAttentionCueCenter {}
        )
    }

    /// A pinned window's workspace detail must fetch/observe agents and
    /// notes over its own session's backend, never the default one.
    @MainActor
    @Test func workspaceDetailStoresRouteOverTheSessionConnection() {
        let fake = FakeConnectionManager()
        let view = WorkspaceDetailView(
            workspaceId: "ws-1",
            session: makePinnedSession(connection: fake),
            storesCache: WorkspaceDetailStoresCache()
        )

        #expect(view.agentStoreConnectionID == ObjectIdentifier(fake))
        #expect(view.noteStoreConnectionID == ObjectIdentifier(fake))
        #expect(view.changesStoreConnectionID == ObjectIdentifier(fake))
        #expect(view.agentStoreConnectionID != ObjectIdentifier(ConnectionManager.shared))
        #expect(view.noteStoreConnectionID != ObjectIdentifier(ConnectionManager.shared))
        #expect(view.changesStoreConnectionID != ObjectIdentifier(ConnectionManager.shared))
    }

    /// Same contract for the note detail: its note/agent stores are bound
    /// to the session that opened the note.
    @MainActor
    @Test func noteDetailStoresRouteOverTheSessionConnection() {
        let fake = FakeConnectionManager()
        let view = NoteDetailView(
            noteId: "n-1",
            workspaceId: "ws-1",
            noteTitle: "Note",
            session: makePinnedSession(connection: fake)
        )

        #expect(view.noteStoreConnectionID == ObjectIdentifier(fake))
        #expect(view.agentStoreConnectionID == ObjectIdentifier(fake))
        #expect(view.noteStoreConnectionID != ObjectIdentifier(ConnectionManager.shared))
        #expect(view.agentStoreConnectionID != ObjectIdentifier(ConnectionManager.shared))
    }
}

extension WorkspaceDetailViewTests {
    @MainActor
    @Test(arguments: [false, true])
    func headingUsesCapToBaselineSpacing(hasSummary: Bool) throws {
        let image = try spacingImage(heading(summary: hasSummary ? "READY FOR REVIEW" : nil), width: 402)
        let bands = image.inkBands(in: 24..<378)
        try #require(bands.count == (hasSummary ? 3 : 2), "Rendered heading bands: \(bands)")
        #expect(abs(bands[0].lowerBound - 64) <= 2)
        for (previous, next) in zip(bands, bands.dropFirst()) {
            #expect(abs(next.lowerBound - previous.upperBound - 20) <= 2)
        }
        #expect(abs(image.height - bands[bands.count - 1].upperBound - 32) <= 2)
    }

    @MainActor
    @Test func headingAndNestedTitlesStillGrowAtAccessibilitySizes() throws {
        let title = "BUILD THE WORKSPACE INTERFACE AND VERIFY ALL INTERACTIONS"
        let normal = try spacingImage(heading(title: title), width: 402)
        let accessible = try spacingImage(heading(title: title), width: 402, category: .accessibility5)
        #expect(accessible.height > normal.height)
        let normalTask = try spacingImage(nestedTask(title), width: 354)
        let accessibleTask = try spacingImage(nestedTask(title), width: 354, category: .accessibility5)
        #expect(accessibleTask.height > normalTask.height)
    }

    @MainActor
    @Test(arguments: ["BUILD PLUGIN", "BUILD THE PLUGIN INTERFACE AND VERIFY INTERACTIONS"])
    func nestedCheckboxCentersOnlySingleLineTitles(title: String) throws {
        let image = try spacingImage(nestedTask(title), width: 354)
        let bands = image.inkBands(in: 96..<354)
        let first = try #require(bands.first)
        if bands.count == 1 {
            #expect(image.height == 24)
            #expect(abs(Double(first.lowerBound + first.upperBound) / 2 - 12) <= 1)
        } else {
            #expect(first.lowerBound <= 1, "Wrapped title caps must align with the checkbox top")
        }
    }

    @MainActor
    private func heading(title: String = "BUILD SPEC WRITER", summary: String? = nil) -> some View {
        WorkspaceDetailHeading(
            workspaceId: "spacing",
            title: title,
            createdAt: nil,
            repositoryOwner: "INTENT",
            repositoryName: "REPO",
            statusMessage: summary,
            titleEditor: WorkspaceTitleEditor()
        ) {}
    }

    @MainActor
    private func nestedTask(_ title: String) -> some View {
        NoteRowView(
            note: Note(
                id: "task",
                title: title,
                content: "",
                tags: [],
                isDefault: false,
                isArchived: false,
                taskStatus: "complete",
                parentId: "spec",
                createdAt: "",
                updatedAt: ""
            ),
            depth: 1,
            colorScheme: .light
        )
    }

    @MainActor
    private func spacingImage(
        _ view: some View, width: CGFloat, category: DynamicTypeSize = .large
    ) throws -> WorkspaceSpacingImage {
        let renderer = ImageRenderer(content: view
            .frame(width: width)
            .background(.white)
            .environment(\.colorScheme, .light)
            .environment(\.dynamicTypeSize, category)
            .environment(\.legibilityWeight, .regular))
        renderer.scale = 1
        let image = try #require(renderer.cgImage)
        Attachment.record(try #require(UIImage(cgImage: image).pngData()), named: "workspace-spacing.png")
        return try WorkspaceSpacingImage(image)
    }
}

/// Inspect rendered cap boxes rather than asserting which layout helpers the views use.
private struct WorkspaceSpacingImage {
    private static let bytesPerPixel = 4
    private static let bitsPerChannel = 8
    private static let inkThreshold: UInt8 = 180
    let width: Int
    let height: Int
    let pixels: [UInt8]

    init(_ image: CGImage) throws {
        width = image.width
        height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * Self.bytesPerPixel)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(
                data: buffer.baseAddress,
                width: image.width,
                height: image.height,
                bitsPerComponent: Self.bitsPerChannel,
                bytesPerRow: image.width * Self.bytesPerPixel,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            // Fractional view heights can leave a transparent edge in the rounded bitmap.
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(bounds)
            context.draw(image, in: bounds)
        }
        pixels = bytes
    }

    func inkBands(in columns: Range<Int>) -> [Range<Int>] {
        var bands: [Range<Int>] = []
        for row in 0..<height {
            let hasInk = columns.contains { column in
                let offset = (row * width + column) * Self.bytesPerPixel
                return pixels[offset] < Self.inkThreshold && pixels[offset + 1] < Self.inkThreshold && pixels[offset + 2] < Self.inkThreshold
            }
            guard hasInk else { continue }
            if let last = bands.last, last.upperBound == row {
                bands[bands.count - 1] = last.lowerBound..<(row + 1)
            } else {
                bands.append(row..<(row + 1))
            }
        }
        return bands
    }
}
