import CoreGraphics
@testable import Intent
import Testing

struct WorkspaceSearchMotionTests {
    private let header = WorkspaceSearchPlacement(frame: CGRect(x: 322, y: 220, width: 56, height: 56), isSearching: false)
    private let input = WorkspaceSearchPlacement(frame: CGRect(x: 8, y: 500, width: 386, height: 56), isSearching: true)

    @Test func headerMeasurementsFollowScrollingImmediatelyWhenIdle() {
        var motion = WorkspaceSearchMotion()
        #expect(motion.update(header, isSearching: false, reduceMotion: false)?.animated == false)
        var scrolled = header
        scrolled.frame.origin.y -= 100
        #expect(motion.update(scrolled, isSearching: false, reduceMotion: false)?.animated == false)
        #expect(motion.placement == scrolled)
    }

    @Test func everyHeaderMeasurementDuringClosingKeepsAnimating() throws {
        var motion = expandedMotion()
        let closing = try #require(motion.update(header, isSearching: false, reduceMotion: false))
        #expect(closing.animated)
        var movingHeader = header
        movingHeader.frame.origin.y += 20
        let retarget = try #require(motion.update(movingHeader, isSearching: false, reduceMotion: false))
        #expect(retarget.animated)
        motion.complete(revision: closing.revision)
        #expect(motion.isAnimating)
        movingHeader.frame.origin.y += 20
        let latest = try #require(motion.update(movingHeader, isSearching: false, reduceMotion: false))
        #expect(latest.animated)
        motion.complete(revision: latest.revision)
        movingHeader.frame.origin.y += 20
        #expect(motion.update(movingHeader, isSearching: false, reduceMotion: false)?.animated == false)
    }

    @Test func keyboardMovementAndReopeningRetargetWithoutAnOldCompletionStoppingThem() throws {
        var motion = expandedMotion()
        var aboveKeyboard = input
        aboveKeyboard.frame.origin.y -= 200
        #expect(motion.update(aboveKeyboard, isSearching: true, reduceMotion: false)?.animated == true)
        let closing = try #require(motion.update(header, isSearching: false, reduceMotion: false))
        let reopening = try #require(motion.update(aboveKeyboard, isSearching: true, reduceMotion: false))
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
        #expect(motion.update(header, isSearching: true, reduceMotion: false) == nil)
        #expect(motion.update(WorkspaceSearchPlacement(frame: .zero, isSearching: true), isSearching: true, reduceMotion: false) == nil)
        #expect(motion.update(input, isSearching: true, reduceMotion: false) == nil)
        #expect(motion.placement == input)
        #expect(motion.revision == revision)
        #expect(motion.isAnimating)
    }

    @Test func reduceMotionDisablesOpeningClosingAndRetargeting() {
        var motion = WorkspaceSearchMotion()
        #expect(motion.update(header, isSearching: false, reduceMotion: true)?.animated == false)
        #expect(motion.update(input, isSearching: true, reduceMotion: true)?.animated == false)
        #expect(motion.update(header, isSearching: false, reduceMotion: true)?.animated == false)
        #expect(!motion.isAnimating)
    }

    private func expandedMotion() -> WorkspaceSearchMotion {
        var motion = WorkspaceSearchMotion()
        _ = motion.update(header, isSearching: false, reduceMotion: false)
        _ = motion.update(input, isSearching: true, reduceMotion: false)
        return motion
    }
}
