import SwiftUI
import Testing
@testable import Intent

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
            "ralph": .ralph,
        ]
        for (specialist, design) in expected {
            #expect(AgentAvatarDesign.design(agentId: "agent-1", specialist: specialist) == design)
        }
    }

    @Test func builtinMappingIgnoresAgentId() {
        #expect(
            AgentAvatarDesign.design(agentId: "agent-a", specialist: "implementor")
                == AgentAvatarDesign.design(agentId: "agent-b", specialist: "implementor"))
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
            #expect(
                AgentAvatarDesign.fallbackDesign(agentId: id)
                    == AgentAvatarDesign.fallbackDesign(agentId: id))
        }
    }

    @Test func fallbackVariesAcrossAgentIds() {
        let designs = Set((0..<64).map { AgentAvatarDesign.fallbackDesign(agentId: "agent-\($0)") })
        #expect(designs.count > 1)
    }

    // MARK: - Glyph geometry

    @Test func everyDesignHasGlyphGeometryWithinArtBounds() {
        let limit = CGRect(x: -2, y: -2, width: 20, height: 20)
        for design in AgentAvatarDesign.allCases {
            let glyph = design.glyph
            #expect(
                !(glyph.strokePath.isEmpty && glyph.fillPath.isEmpty),
                "\(design.rawValue) has no geometry")
            for path in [glyph.strokePath, glyph.fillPath] where !path.isEmpty {
                #expect(
                    limit.contains(path.boundingRect),
                    "\(design.rawValue) outside 16×16 art bounds: \(path.boundingRect)")
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
}
