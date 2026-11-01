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
        let shortcuts = WorkspaceResourceShortcuts(workspaceId: "workspace").environment(session)
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

        let saved = WorkspaceDetailView(workspaceId: "saved-workspace", session: session, persistence: persistence)
        let unsaved = WorkspaceDetailView(workspaceId: "new-workspace", session: session, persistence: persistence)

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
            session: makePinnedSession(connection: fake)
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

    /// #752: count-only and loaded groups paint tiles inline with the label; #576: no 44 pt band of blank space.
    @MainActor
    @Test(arguments: [ColorScheme.light, .dark], [false, true])
    func delegatedSummaryPaintsInlineTilesWithoutTouchFramePadding(scheme: ColorScheme, loaded: Bool) throws {
        let agents = loaded ? (0..<3).map { delegatedAgent(id: "child-\($0)") } : []
        let row = DelegatedAgentsRow(
            agents: agents, totalCount: 3, runningCount: 1, isExpanded: false, colorScheme: scheme
        ) {}
        let image = try spacingImage(row, width: 354, scheme: scheme)
        #expect(image.height == 24, "The touch target must not add visible height")
        let stackStart = Int(WorkspaceDetailStyle.avatarSize + WorkspaceDetailStyle.avatarSpacing)
        // Each tile draws a 1 pt background-colored border; antialiasing can leave that edge pixel faintly painted.
        let runs = image.paintedColumns(in: stackStart..<354, mergingGapsBelow: 6)
        let stack = try #require(runs.first)
        let message = "Three overlapping 24 pt tiles must be painted: \(runs)"
        #expect((stackStart...(stackStart + 1)).contains(stack.lowerBound), "\(message)")
        #expect(((stackStart + 59)...(stackStart + 60)).contains(stack.upperBound), "\(message)")
        let label = try #require(runs.dropFirst().first, "The summary label must sit beside the stack")
        #expect(abs(label.lowerBound - stack.upperBound - 16) <= 2)
        for tile in 0..<3 {
            let center = stackStart + tile * 18 + 12
            let bands = image.paintedBands(in: center..<(center + 1))
            #expect(bands.count == 1 && bands[0].lowerBound <= 1 && bands[0].upperBound >= 23, "Tile \(tile) must fill the row: \(bands)")
        }
    }

    @MainActor
    @Test func accessibilitySizesStackTheDelegatedSummary() throws {
        let row = DelegatedAgentsRow(
            agents: [], totalCount: 3, runningCount: nil, isExpanded: false, colorScheme: .light
        ) {}
        let image = try spacingImage(row, width: 354, category: .accessibility1)
        let start = Int(WorkspaceDetailStyle.avatarSize + WorkspaceDetailStyle.avatarSpacing)
        let bands = image.paintedBands(in: start..<354)
        #expect(bands.count == 2, "Tiles and label must stack vertically: \(bands)")
        #expect((bands.first?.lowerBound ?? 24) <= 1 && (bands.first?.upperBound ?? 0) >= 23, "The tiles must lead: \(bands)")
        #expect(bands.last?.lowerBound ?? 0 >= 32, "The label must sit 8 pt below the tiles: \(bands)")
    }

    /// #576: 16 pt title/message gap and 32 pt from the message to the delegated stack.
    @MainActor
    @Test(arguments: [ColorScheme.light, .dark])
    func agentRowUsesFigmaMessageAndStackSpacing(scheme: ColorScheme) throws {
        let parent = delegatedAgent(id: "parent", digest: "Tests finished")
        let row = WorkspaceAgentTreeRow(
            button: WorkspaceAgentButton(agent: parent, colorScheme: scheme, indented: false, onSelect: {}, onMute: {}),
            depth: 0,
            group: WorkspaceAgentGroupSnapshot(
                agents: [], totalCount: 2, runningCount: 0, isExpanded: false, identifier: "group", status: .ready
            ),
            colorScheme: scheme,
            onLoadGroup: {},
            onToggle: {},
            onRetry: {}
        )
        let image = try spacingImage(row, width: 354, scheme: scheme)
        let start = Int(WorkspaceDetailStyle.avatarSize + WorkspaceDetailStyle.avatarSpacing)
        let text = image.paintedBands(in: (start + 30)..<354)
        try #require(text.count == 3, "Title, message and summary label bands: \(text)")
        let tileBands = image.paintedBands(in: (start + 4)..<(start + 5))
        let tile = try #require(tileBands.last)
        #expect(tile.count >= 22)
        #expect(abs(image.height - tile.upperBound) <= 1, "The stack must end the row without touch padding")
        let titleGap = text[1].lowerBound - text[0].upperBound
        let stackGap = tile.lowerBound - text[1].upperBound
        #expect((18...24).contains(titleGap), "Title/message ink gap: \(titleGap)")
        #expect((32...38).contains(stackGap), "Message/stack ink gap: \(stackGap)")
    }

    private func delegatedAgent(id: String, digest: String? = nil) -> AgentSession {
        AgentSession(
            id: id,
            name: "Spec writer",
            status: "Idle",
            isBackground: false,
            isStreaming: false,
            isProcessing: false,
            isResponding: false,
            isWaitingForOtherAgents: false,
            waitingForAgentIds: [],
            createdAt: nil,
            updatedAt: nil,
            lastActivity: nil,
            lastAgentResponse: nil,
            lastUserMessage: nil,
            lastMessageRole: nil,
            digest: digest,
            specialist: nil,
            createdByAgentId: nil,
            attentionRequestKind: nil,
            attentionRequestReason: nil,
            attentionRequestTimestamp: nil,
            pendingQuestionsMessageId: nil,
            dismissedQuestionsMessageId: nil
        )
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
        _ view: some View, width: CGFloat, category: DynamicTypeSize = .large, scheme: ColorScheme = .light
    ) throws -> WorkspaceSpacingImage {
        let renderer = ImageRenderer(content: view
            .frame(width: width)
            .background(WorkspaceDetailStyle.background(for: scheme))
            .environment(\.colorScheme, scheme)
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
    private static let paintTolerance = 8
    private static let colorChannels = 3
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

    /// Rows containing any pixel that differs from the bottom-trailing background.
    func paintedBands(in columns: Range<Int>) -> [Range<Int>] {
        runs(count: height) { row in columns.contains { isPainted(column: $0, row: row) } }
    }

    /// Columns containing any pixel that differs from the bottom-trailing background.
    func paintedColumns(in columns: Range<Int>, mergingGapsBelow gap: Int = 1) -> [Range<Int>] {
        let painted = runs(count: width) { column in
            columns.contains(column) && (0..<height).contains { isPainted(column: column, row: $0) }
        }
        return painted.reduce(into: []) { merged, run in
            if let last = merged.last, run.lowerBound - last.upperBound < gap {
                merged[merged.count - 1] = last.lowerBound..<run.upperBound
            } else {
                merged.append(run)
            }
        }
    }

    private func isPainted(column: Int, row: Int) -> Bool {
        let offset = (row * width + column) * Self.bytesPerPixel
        let background = ((height - 1) * width + width - 1) * Self.bytesPerPixel
        return (0..<Self.colorChannels).contains { abs(Int(pixels[offset + $0]) - Int(pixels[background + $0])) > Self.paintTolerance }
    }

    private func runs(count: Int, where included: (Int) -> Bool) -> [Range<Int>] {
        var result: [Range<Int>] = []
        for index in 0..<count where included(index) {
            if let last = result.last, last.upperBound == index {
                result[result.count - 1] = last.lowerBound..<(index + 1)
            } else {
                result.append(index..<(index + 1))
            }
        }
        return result
    }
}
