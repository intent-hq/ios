@testable import Intent
import SwiftUI
import Testing

@MainActor
struct AssistantLauncherLayoutTests {
    @Test(arguments: [3, 4, 5, 6])
    func allMenuActionsFitWhenMinimumWidthsAreAvailable(actionCount: Int) {
        let count = CGFloat(actionCount)
        let spacing: CGFloat = 8
        let minimumWidth: CGFloat = 160
        let minimumRowWidth = count * minimumWidth + (count - 1) * spacing
        for width in stride(from: minimumRowWidth, through: 1400, by: 1) {
            let tile = HomeActionTiles.tileWidth(in: width, actionCount: actionCount, accessibility: false)
            #expect(tile >= minimumWidth)
            #expect(tile <= 192)
            #expect(tile * count + (count - 1) * spacing <= width + 0.001)
        }
        #expect(HomeActionTiles.tileWidth(in: minimumRowWidth, actionCount: actionCount, accessibility: false) == minimumWidth)
        #expect(HomeActionTiles.tileWidth(in: minimumRowWidth - 1, actionCount: actionCount, accessibility: false) == 192)
    }

    @Test func menuKeepsScrollingCardsOnNarrowScreensAndWithAccessibilityText() {
        #expect(HomeActionTiles.tileWidth(in: 352, actionCount: 5, accessibility: false) == 172)
        #expect(HomeActionTiles.tileWidth(in: 320, actionCount: 5, accessibility: false) == 160)
        #expect(HomeActionTiles.tileWidth(in: 352, actionCount: 5, accessibility: true) == 352)
        #expect(HomeActionTiles.tileWidth(in: 900, actionCount: 5, accessibility: true) == 392)
    }

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
