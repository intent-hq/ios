@testable import Intent
import SwiftUI
import Testing

/// Tests for the desktop-parity agent avatar design selection (mirrors
/// cloudlands-fe avatar-design.ts) and the ported glyph geometry.
struct AgentAvatarDesignTests {
    // MARK: - Builtin specialist mapping

    @Test func mapsBuiltinSpecialistsToTheirDesigns() {
        let expected: [String: AgentAvatarDesign] = [
            "coordinator": .coordinator,
            "spec-writer": .coordinator,
            "implementor": .implementor,
            "verifier": .verifier,
            "developer": .verifier,
            "pr-reviewer": .prReviewer,
            "ui-designer": .uiDesigner,
            "chief-of-staff": .chiefOfStaff,
            "ralph": .ralph
        ]
        for (specialist, design) in expected {
            #expect(AgentAvatarDesign.design(agentId: "agent-1", specialist: specialist) == design)
        }
    }

    @Test func builtinMappingIgnoresAgentId() {
        #expect(
            AgentAvatarDesign.design(agentId: "agent-a", specialist: "implementor")
                == AgentAvatarDesign.design(agentId: "agent-b", specialist: "implementor")
        )
    }

    // MARK: - Icon resolution (PROTOCOL §5.11)

    @Test func iconResolvesAheadOfSpecialistMapAndFallback() {
        for icon in AgentAvatarDesign.builtinDesigns {
            #expect(AgentAvatarDesign.design(
                agentId: "agent-a",
                specialist: "implementor",
                icon: icon.rawValue
            ) == icon)
            #expect(AgentAvatarDesign.design(
                agentId: "agent-a",
                specialist: "custom-specialist",
                icon: icon.rawValue
            ) == icon)
            #expect(AgentAvatarDesign.design(
                agentId: "agent-a",
                specialist: nil,
                icon: icon.rawValue
            ) == icon)
        }
    }

    @Test func unknownOrAbsentIconsDegradeToIdMapThenFallback() {
        for icon in [nil, "", "not-a-design", "fallback-glasses"] {
            #expect(AgentAvatarDesign.design(
                agentId: "agent-a",
                specialist: "implementor",
                icon: icon
            ) == .implementor)
            #expect(AgentAvatarDesign.design(
                agentId: "agent-a",
                specialist: "custom-specialist",
                icon: icon
            )
                == AgentAvatarDesign.fallbackDesign(agentId: "agent-a"))
        }
    }

    @Test func iconValidationAcceptsBuiltinDesignsOnly() {
        for design in AgentAvatarDesign.builtinDesigns {
            #expect(AgentAvatarDesign.isBuiltinDesign(design.rawValue))
        }
        for value in ["", "not-a-design", "fallback-glasses", "spec-writer"] {
            #expect(!AgentAvatarDesign.isBuiltinDesign(value))
        }
    }

    // MARK: - Fallback selection

    @Test func unknownSpecialistUsesFallbackDesign() {
        let design = AgentAvatarDesign.design(agentId: "agent-x", specialist: "quantum-entangler")
        #expect(AgentAvatarDesign.fallbackDesigns.contains(design))
    }

    @Test func nilSpecialistUsesFallbackDesign() {
        let design = AgentAvatarDesign.design(agentId: "agent-x", specialist: nil)
        #expect(AgentAvatarDesign.fallbackDesigns.contains(design))
    }

    @Test func fallbackIsDeterministicPerAgentId() {
        let ids = ["agent-123", "agent-456", "", "0d9c66aa-1c9e-4a09-b52f-1f6f7a10a1de", "AGENT-123"]
        for id in ids {
            let firstDesign = AgentAvatarDesign.fallbackDesign(agentId: id)
            let secondDesign = AgentAvatarDesign.fallbackDesign(agentId: id)
            #expect(firstDesign == secondDesign)
        }
    }

    @Test func fallbackVariesAcrossAgentIds() {
        let designs = Set((0..<64).map { AgentAvatarDesign.fallbackDesign(agentId: "agent-\($0)") })
        #expect(designs.count > 1)
    }

    @Test func fallbackMatchesDesktopFixtures() {
        // Expected values computed with the desktop JS implementation:
        // stringToSeededRandom(agentId).pick(fallbackAgentAvatarDesigns)
        // (cloudlands-fe hash.ts + avatar-design.ts). Covers all six
        // fallback designs.
        let fixtures: [(String, AgentAvatarDesign)] = [
            ("", .fallbackGlasses),
            ("a", .fallbackDots),
            ("agent-123", .fallbackCode),
            ("agent-456", .fallbackDots),
            ("AGENT-123", .fallbackCrown),
            ("0d9c66aa-1c9e-4a09-b52f-1f6f7a10a1de", .fallbackDots),
            ("agent-0", .fallbackGlasses),
            ("agent-1", .fallbackCrownMouth),
            ("agent-5", .fallbackCrownInverted),
            ("agent-11", .fallbackCrown),
            // Seeds where the JS float64 LCG step loses low bits and picks a
            // different design than exact integer math would — regression
            // coverage for the Double-based LCG step.
            ("agent-750158", .fallbackCrownMouth),
            ("x2191079", .fallbackGlasses)
        ]
        for (agentId, expected) in fixtures {
            #expect(
                AgentAvatarDesign.fallbackDesign(agentId: agentId) == expected,
                "\(agentId)"
            )
        }
    }

    // MARK: - Glyph geometry

    @Test func everyDesignHasGlyphGeometryWithinArtBounds() {
        let limit = CGRect(x: -2, y: -2, width: 20, height: 20)
        for design in AgentAvatarDesign.allCases {
            let glyph = design.glyph
            #expect(
                !(glyph.strokePath.isEmpty && glyph.fillPath.isEmpty),
                "\(design.rawValue) has no geometry"
            )
            for path in [glyph.strokePath, glyph.fillPath] where !path.isEmpty {
                #expect(
                    limit.contains(path.boundingRect),
                    "\(design.rawValue) outside 16×16 art bounds: \(path.boundingRect)"
                )
            }
        }
    }

    @Test func invertedCrownIsFlippedCrown() {
        let crown = AgentAvatarDesign.fallbackCrown.glyph.strokePath.boundingRect
        let inverted = AgentAvatarDesign.fallbackCrownInverted.glyph.strokePath.boundingRect
        #expect(crown != inverted)
        #expect(abs(crown.width - inverted.width) < 0.001)
        #expect(abs(crown.height - inverted.height) < 0.001)
    }

    @Test func svgParserSupportsImplicitLinesAxisLinesAndCurves() {
        let lines = Path(svgPathData: "M1 2,3 4H5V6")
        #expect(lines.boundingRect == CGRect(x: 1, y: 2, width: 4, height: 4))

        let curve = Path(svgPathData: "M0 0C1 2 3 4 5 6")
        #expect(!curve.isEmpty)
        #expect(curve.boundingRect == CGRect(x: 0, y: 0, width: 5, height: 6))
    }

    @Test func svgParserStopsAtUnsupportedCommandWithoutDiscardingPriorPath() {
        let path = Path(svgPathData: "M0 0L2 2ZL10 10")
        #expect(path.boundingRect == CGRect(x: 0, y: 0, width: 2, height: 2))
    }
}
