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
    }

    @Test func contentButtonsShowGazeFeedbackUnlessTheirContainerDrawsIt() throws {
        let style = try source("Intent/DesignSystem/IntentButtonStyle.swift")
        let content = try #require(style.components(separatedBy: "struct IntentContentButtonStyle: ButtonStyle {").dropFirst().first)
            .components(separatedBy: "struct IntentIconButton:")[0]
        #expect(content.contains(".visionButtonHover(isEnabled: isEnabled && !containerDrawsHover)"))
        // Rows and shaped labels that draw their own highlight opt out, so
        // a control never stacks two highlights.
        let helpers = try source("Intent/DesignSystem/VisionHitTarget.swift")
        for helper in ["func visionListRowHitTarget()", "func visionCardRowButton("] {
            let body = try #require(helpers.components(separatedBy: helper).dropFirst().first)
                .components(separatedBy: "#endif")[0]
            #expect(body.contains(".visionContainerDrawsHover()"), "\(helper) must suppress the button style's highlight")
        }
        let search = try source("Intent/Views/Workspaces/WorkspaceSearchBar.swift")
        #expect(search.contains(".visionContainerDrawsHover(visionWorkspaceHover)"))
    }

    @Test func gazeHelpersAreNoOpsOffVisionOS() throws {
        let helpers = try source("Intent/DesignSystem/VisionHitTarget.swift")
        let visionGuard = "#if os(" + "visionOS)"
        for helper in ["func visionButtonHover(", "func visionHoverShape("] {
            let body = try #require(helpers.components(separatedBy: helper).dropFirst().first)
            let vision = try #require(body.components(separatedBy: visionGuard).dropFirst().first)
                .components(separatedBy: "#else")[0]
            #expect(vision.contains("hoverEffect"))
            let fallback = try #require(body.components(separatedBy: "#else").dropFirst().first)
                .components(separatedBy: "#endif")[0]
            #expect(fallback.trimmingCharacters(in: .whitespacesAndNewlines) == "self")
        }
    }

    @Test func collapsibleHeadingsHighlightOnlyTheirChevron() throws {
        let header = try source("Intent/Views/Workspaces/CollapsibleSectionHeader.swift")
        let chevron = try #require(header.components(separatedBy: "Image(.chevronRight)").dropFirst().first)
            .components(separatedBy: ".padding(insets)")[0]
        #expect(chevron.contains(".visionGroupedHoverHint(padding: Self.chevronHoverPadding)"))
        // The whole heading activates the hint but draws no row-wide highlight.
        #expect(header.contains(".visionHoverGroup()"))
        #expect(header.contains(".buttonStyle(IntentContentButtonStyle())\n        .visionContainerDrawsHover()"))
    }
}
