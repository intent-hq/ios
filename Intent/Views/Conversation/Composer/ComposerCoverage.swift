import Observation
import SwiftUI

/// The modal layers (sheets, full-screen covers) currently open in one
/// window, so a chat can tell whether something covers it. Each covering
/// layer sits one level above the view that presented it; a chat composer is
/// foremost only when no active layer sits above its own level. On visionOS
/// this keeps exactly one floating composer — the foremost chat's — visible
/// and interactive (the Assistant sheet over a chat used to show two).
@MainActor
@Observable
final class ComposerCoverage {
    private var layers: [UUID: Int] = [:]

    func cover(_ id: UUID, depth: Int) {
        layers[id] = depth
    }

    func uncover(_ id: UUID) {
        layers[id] = nil
    }

    /// Whether a view at `depth` is in front of every active covering layer.
    func isForemost(depth: Int) -> Bool {
        !layers.values.contains { $0 > depth }
    }
}

extension EnvironmentValues {
    /// How many covering modal layers enclose this view (0 for window content).
    @Entry var composerLayerDepth = 0
}

/// Registers modal content as a covering layer while it is on screen.
private struct ComposerCoveringLayer: ViewModifier {
    @Environment(ComposerCoverage.self) private var coverage: ComposerCoverage?
    @Environment(\.composerLayerDepth) private var parentDepth
    @State private var id = UUID()

    func body(content: Content) -> some View {
        let depth = parentDepth + 1
        content
            .environment(\.composerLayerDepth, depth)
            .onAppear { coverage?.cover(id, depth: depth) }
            .onDisappear { coverage?.uncover(id) }
    }
}

/// Registers in-window content (the open Intent menu) as a covering layer
/// while `isActive`; withdrawing it, or unmounting it, uncovers the chats.
private struct ComposerConditionalCoveringLayer: ViewModifier {
    let isActive: Bool
    @Environment(ComposerCoverage.self) private var coverage: ComposerCoverage?
    @Environment(\.composerLayerDepth) private var parentDepth
    @State private var id = UUID()

    func body(content: Content) -> some View {
        content
            .onAppear { update(isActive) }
            .onChange(of: isActive) { _, active in update(active) }
            .onDisappear { coverage?.uncover(id) }
    }

    private func update(_ active: Bool) {
        if active {
            coverage?.cover(id, depth: parentDepth + 1)
        } else {
            coverage?.uncover(id)
        }
    }
}

extension View {
    /// Marks sheet or full-screen-cover content that covers the chats beneath
    /// it: their floating composers withdraw until it is dismissed (drafts
    /// and pending attachments stay on the conversation model).
    func coversConversationComposers() -> some View {
        modifier(ComposerCoveringLayer())
    }

    /// Covers the chats beneath this view while `isActive` — for in-window
    /// overlays such as the open Intent menu. Coverage is temporary: covered
    /// composers hide (no input, focus or accessibility) but keep drafts,
    /// pending attachments and in-flight imports, and return on withdrawal.
    func coversConversationComposers(while isActive: Bool) -> some View {
        modifier(ComposerConditionalCoveringLayer(isActive: isActive))
    }
}
