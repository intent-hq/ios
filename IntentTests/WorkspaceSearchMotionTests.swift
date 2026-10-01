import CoreGraphics
@testable import Intent
import Testing

struct WorkspaceSearchMotionTests {
    private let header = WorkspaceSearchPlacement(frame: CGRect(x: 322, y: 220, width: 56, height: 56), isSearching: false)
    private let input = WorkspaceSearchPlacement(frame: CGRect(x: 8, y: 500, width: 386, height: 56), isSearching: true)

    @Test func headerMeasurementsFollowScrollingImmediatelyWhenIdle() {
        var motion = WorkspaceSearchMotion()
        let initial = motion.update(header, isSearching: false, reduceMotion: false)
        #expect(initial?.animated == false)
        var scrolled = header
        scrolled.frame.origin.y -= 100
        let scroll = motion.update(scrolled, isSearching: false, reduceMotion: false)
        #expect(scroll?.animated == false)
        #expect(motion.placement == scrolled)
    }

    @Test func everyHeaderMeasurementDuringClosingKeepsAnimating() throws {
        var motion = expandedMotion()
        let closeUpdate = motion.update(header, isSearching: false, reduceMotion: false)
        let closing = try #require(closeUpdate)
        #expect(closing.animated)
        var movingHeader = header
        movingHeader.frame.origin.y += 20
        let retargetUpdate = motion.update(movingHeader, isSearching: false, reduceMotion: false)
        let retarget = try #require(retargetUpdate)
        #expect(retarget.animated)
        motion.complete(revision: closing.revision)
        #expect(motion.isAnimating)
        movingHeader.frame.origin.y += 20
        let latestUpdate = motion.update(movingHeader, isSearching: false, reduceMotion: false)
        let latest = try #require(latestUpdate)
        #expect(latest.animated)
        motion.complete(revision: latest.revision)
        movingHeader.frame.origin.y += 20
        let settled = motion.update(movingHeader, isSearching: false, reduceMotion: false)
        #expect(settled?.animated == false)
    }

    @Test func keyboardMovementAndReopeningRetargetWithoutAnOldCompletionStoppingThem() throws {
        var motion = expandedMotion()
        var aboveKeyboard = input
        aboveKeyboard.frame.origin.y -= 200
        let keyboard = motion.update(aboveKeyboard, isSearching: true, reduceMotion: false)
        #expect(keyboard?.animated == true)
        let closeUpdate = motion.update(header, isSearching: false, reduceMotion: false)
        let closing = try #require(closeUpdate)
        let reopenUpdate = motion.update(aboveKeyboard, isSearching: true, reduceMotion: false)
        let reopening = try #require(reopenUpdate)
        #expect(reopening.animated)
        motion.complete(revision: closing.revision)
        #expect(motion.isAnimating)
        #expect(motion.placement == aboveKeyboard)
        motion.complete(revision: reopening.revision)
        #expect(!motion.isAnimating)
    }

    @Test func staleEmptyAndDuplicateMeasurementsDoNotReplaceTheActiveTarget() {
        var motion = expandedMotion()
        let revision = motion.revision
        let stale = motion.update(header, isSearching: true, reduceMotion: false)
        let empty = motion.update(WorkspaceSearchPlacement(frame: .zero, isSearching: true), isSearching: true, reduceMotion: false)
        let duplicate = motion.update(input, isSearching: true, reduceMotion: false)
        #expect(stale == nil)
        #expect(empty == nil)
        #expect(duplicate == nil)
        #expect(motion.placement == input)
        #expect(motion.revision == revision)
        #expect(motion.isAnimating)
    }

    @Test func reduceMotionDisablesOpeningClosingAndRetargeting() {
        var motion = WorkspaceSearchMotion()
        let initial = motion.update(header, isSearching: false, reduceMotion: true)
        let opening = motion.update(input, isSearching: true, reduceMotion: true)
        let closing = motion.update(header, isSearching: false, reduceMotion: true)
        #expect(initial?.animated == false)
        #expect(opening?.animated == false)
        #expect(closing?.animated == false)
        #expect(!motion.isAnimating)
    }

    private func expandedMotion() -> WorkspaceSearchMotion {
        var motion = WorkspaceSearchMotion()
        _ = motion.update(header, isSearching: false, reduceMotion: false)
        _ = motion.update(input, isSearching: true, reduceMotion: false)
        return motion
    }
}
