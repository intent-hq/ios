import Observation
import SwiftUI

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

    func isForemost(depth: Int) -> Bool {
        !layers.values.contains { $0 > depth }
    }
}

extension EnvironmentValues {
    @Entry var composerLayerDepth = 0
}

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
    func coversConversationComposers() -> some View {
        modifier(ComposerCoveringLayer())
    }

    func coversConversationComposers(while isActive: Bool) -> some View {
        modifier(ComposerConditionalCoveringLayer(isActive: isActive))
    }
}
