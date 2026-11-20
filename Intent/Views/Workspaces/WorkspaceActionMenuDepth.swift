import SwiftUI

enum WorkspaceAttentionCuePresentation: Equatable {
    case raised
    case resting
    case suppressed

    static func resolve(needsInput: Bool, actionMenuOpen: Bool) -> Self {
        guard needsInput else { return .resting }
        return actionMenuOpen ? .suppressed : .raised
    }

    static func resolve(for workspace: Workspace, actionMenuOpen: Bool) -> Self {
        resolve(needsInput: workspaceNeedsInput(workspace), actionMenuOpen: actionMenuOpen)
    }

    var liftsTowardViewer: Bool { self == .raised }
    var isHidden: Bool { self == .suppressed }
}

enum WorkspaceActionMenuDepth {
    static let tileZOffset: CGFloat = 24

    static func usesGlass(reduceTransparency: Bool) -> Bool {
        !reduceTransparency
    }
}

extension EnvironmentValues {
    @Entry var workspaceActionMenuOpen = false
}

extension View {
    @ViewBuilder
    func homeActionTileSurface(cornerRadius: CGFloat, fill: Color) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .circular)
        #if os(visionOS)
        self.modifier(VisionActionTileSurface(shape: shape, fill: fill))
        #else
        self.background(fill, in: shape)
        #endif
    }

    @ViewBuilder
    func visionActionMenuDepth() -> some View {
        #if os(visionOS)
        self.offset(z: WorkspaceActionMenuDepth.tileZOffset)
        #else
        self
        #endif
    }
}

#if os(visionOS)
private struct VisionActionTileSurface: ViewModifier {
    let shape: RoundedRectangle
    let fill: Color
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        Group {
            if WorkspaceActionMenuDepth.usesGlass(reduceTransparency: reduceTransparency) {
                content.glassBackgroundEffect(in: shape)
            } else {
                content.background(fill, in: shape)
            }
        }
            .contentShape([.interaction, .hoverEffect], shape)
            .hoverEffect(.highlight)
    }
}
#endif
