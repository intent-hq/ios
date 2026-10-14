@testable import Intent
import SwiftUI
import Testing

@MainActor
struct AssistantLauncherLayoutTests {
    @Test func spatialControlsAreModestlyLargerAndFartherFromResizeCorner() {
        let old = AssistantLauncherLayout.handheld
        let spatial = AssistantLauncherLayout.spatial
        #expect(spatial.diameter > old.diameter)
        #expect(spatial.diameter <= old.diameter * 1.25)
        #expect(spatial.closeSize > old.closeSize)
        #expect(spatial.closeSize <= old.closeSize * 1.25)
        #expect(spatial.horizontalInset >= old.horizontalInset + 24)
        #expect(spatial.launcherBottomInset >= old.launcherBottomInset + 24)
        #expect(spatial.menuBottomInset >= old.menuBottomInset + 24)
    }

    @Test func transcriptEndsAboveBothControlStates() {
        let layout = AssistantLauncherLayout.spatial
        let clearance = FloatingComposerPolicy.transcriptBottomClearance(
            host: .floatingOrnament, launcherClearance: layout.scrollClearance
        )
        #expect(clearance > layout.diameter + layout.launcherBottomInset)
        #expect(clearance > layout.closeSize + layout.menuBottomInset)
        #expect(clearance > AssistantLauncherLayout.handheld.scrollClearance)
    }

    @Test func menuAndLauncherKeepTheSameTrailingEdgeAtNarrowWidths() {
        let layout = AssistantLauncherLayout.spatial
        // HomeActionTiles supplies the original 24pt content inset itself.
        #expect(layout.tileExtraInset + 24 == layout.horizontalInset)
        for width: CGFloat in [320, 390, 700, 1400] {
            #expect(width - 2 * layout.horizontalInset >= layout.diameter)
            #expect(width - 2 * layout.horizontalInset >= 160, "at least one full action card fits")
        }
    }

    @Test func handheldLayoutRemainsUnchanged() {
        let layout = AssistantLauncherLayout.handheld
        #expect(layout.diameter == 80)
        #expect(layout.closeSize == 48)
        #expect(layout.horizontalInset == 24)
        #expect(layout.launcherBottomInset == 12)
        #expect(layout.menuBottomInset == 24)
        #expect(layout.tileExtraInset == 0)
        #expect(layout.scrollClearance == 104)
    }

    @Test func hostedControlUsesItsVisibleSizeAndKeepsPaddingOutsideTheButton() {
        for layout in [AssistantLauncherLayout.handheld, .spatial] {
            for isOpen in [false, true] {
                let control = AssistantLaunchButton(isOpen: isOpen, layout: layout) {}
                let host = UIHostingController(rootView: control)
                let size = host.sizeThatFits(in: CGSize(width: 320, height: 300))
                let diameter = isOpen ? layout.closeSize : layout.diameter
                #expect(size.height == diameter)
                #expect(size.width == diameter + 2 * layout.horizontalInset)
            }
        }
    }
}
