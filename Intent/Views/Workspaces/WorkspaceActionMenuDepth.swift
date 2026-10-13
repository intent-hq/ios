import SwiftUI

/// How a workspace row's attention cue presents relative to the Intent menu.
/// On visionOS rows that need input lift toward the viewer; while the menu is
/// open those raised rows are hidden entirely so nothing competes with its
/// action cards. Presentation only: the workspace and its server-owned unread
/// flag are never read-marked, filtered or changed, so still-applicable rows
/// return raised when the menu closes.
enum WorkspaceAttentionCuePresentation: Equatable {
    /// Needs input: the row lifts slightly toward the viewer.
    case raised
    /// No pending input: the row stays in the window plane.
    case resting
    /// Needs input while the Intent menu is open: invisible, takes no input
    /// and is absent from accessibility until the menu closes.
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

/// Depth of the Intent menu's action cards on visionOS.
enum WorkspaceActionMenuDepth {
    /// How far the open menu's cards sit in front of the window plane:
    /// clearly ahead of a raised attention row
    /// (`Constants.WorkspaceRow.attentionCueZOffset`) yet restrained.
    static let tileZOffset: CGFloat = 24

    /// Reduce Transparency replaces see-through glass with an opaque card.
    static func usesGlass(reduceTransparency: Bool) -> Bool {
        !reduceTransparency
    }
}

extension EnvironmentValues {
    /// Whether an enclosing Intent menu is open over this content.
    @Entry var workspaceActionMenuOpen = false
    /// Bottom room a floating Intent launcher needs over this content (0
    /// when no launcher floats here, e.g. while searching or in a sheet).
    @Entry var workspaceActionLauncherClearance: CGFloat = 0
}

extension View {
    /// The action card's surface: native glass with gaze highlighting on
    /// visionOS (opaque under Reduce Transparency); the unchanged solid
    /// control surface on iPhone and iPad.
    @ViewBuilder
    func homeActionTileSurface(cornerRadius: CGFloat, fill: Color) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .circular)
        #if os(visionOS)
        self.modifier(VisionActionTileSurface(shape: shape, fill: fill))
        #else
        self.background(fill, in: shape)
        #endif
    }

    /// Brings the open menu's cards forward in real depth on visionOS. No-op
    /// on other platforms.
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
