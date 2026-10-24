import Foundation
import Testing

/// Source coverage for gaze wiring, which an iOS simulator cannot exercise.
/// Look-and-pinch accuracy still requires a Vision Pro check.
struct WorkspaceControlGazeTests {
    private func source(_ path: String) throws -> String {
        try String(contentsOf: TestSourceInputs.url(for: path), encoding: .utf8)
    }

    @Test func eachSegmentAndSearchOptIntoTheirOwnHoverRegion() throws {
        let source = try source("Intent/Views/Workspaces/WorkspaceSearchBar.swift")
        let switcher = try #require(source.components(separatedBy: "private var viewModeSwitcher: some View {").last)
            .components(separatedBy: "struct WorkspaceSearchButton:")[0]
        #expect(switcher.contains("ForEach(Mode.allCases"))
        #expect(switcher.contains(".visionWorkspaceControlHover(cornerRadius: Constants.WorkspaceSearch.segmentCornerRadius)"))
        #expect(source.contains("visionWorkspaceHover: true"))
        #expect(source.contains("isEnabled: visionWorkspaceHover"))
        #expect(source.contains("HStack(spacing: Constants.WorkspaceSearch.visionSegmentSpacing)"))
    }

    @Test func hoverUsesTheVisibleShapeAndPreservesOtherPlatforms() throws {
        let source = try source("Intent/DesignSystem/VisionHitTarget.swift")
        let helper = try #require(source.components(separatedBy: "func visionWorkspaceControlHover(").dropFirst().first)
        let visionGuard = "#if os(" + "visionOS)"
        let vision = try #require(helper.components(separatedBy: visionGuard).dropFirst().first)
            .components(separatedBy: "#else")[0]
        #expect(vision.contains("if isEnabled"))
        #expect(vision.contains(".contentShape([.interaction, .hoverEffect], .rect(cornerRadius: cornerRadius))"))
        #expect(vision.contains(".hoverEffect(.highlight)"))
        let fallback = try #require(helper.components(separatedBy: "#else").dropFirst().first)
            .components(separatedBy: "#endif")[0]
        #expect(fallback.trimmingCharacters(in: .whitespacesAndNewlines) == "self")
    }

    @Test func segmentSpacingIsOnlyAddedOnVisionOS() throws {
        let source = try source("Intent/DesignSystem/VisionHitTarget.swift")
        let spacing = try #require(source.components(separatedBy: "static var visionSegmentSpacing: CGFloat {").dropFirst().first)
            .components(separatedBy: "#endif")[0]
        let visionGuard = "#if os(" + "visionOS)"
        let vision = try #require(spacing.components(separatedBy: visionGuard).dropFirst().first)
            .components(separatedBy: "#else")[0]
        #expect(vision.trimmingCharacters(in: .whitespacesAndNewlines) == "contentSpacing")
        let fallback = try #require(spacing.components(separatedBy: "#else").dropFirst().first)
        #expect(fallback.trimmingCharacters(in: .whitespacesAndNewlines) == "0")
    }

    @Test func sharedSearchButtonLeavesCreationControlsUnchanged() throws {
        let search = try source("Intent/Views/Workspaces/WorkspaceSearchBar.swift")
        #expect(search.contains("var visionWorkspaceHover = false"))
        let creation = try source("Intent/Views/Workspaces/CreateWorkspaceSelectionPage.swift")
        #expect(creation.contains("WorkspaceSearchButton("))
        #expect(!creation.contains("visionWorkspaceHover:"))
        let style = try source("Intent/DesignSystem/IntentButtonStyle.swift")
        #expect(!style.contains("hoverEffect"), "Do not enable gaze feedback globally for unrelated controls")
    }
}
