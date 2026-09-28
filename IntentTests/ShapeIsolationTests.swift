@testable import Intent
import SwiftUI
import Testing

/// `Shape` conformers must be `nonisolated` (intent-hq/ios#291): SDK 27
/// declares `Shape` and `path(in:)` nonisolated, so under the app's MainActor
/// default isolation an implicitly isolated conformer no longer compiles.
///
/// This suite is itself `nonisolated`, so it builds and evaluates the shapes
/// off the main actor — the calling convention SDK 27 requires of a `Shape` —
/// and pins their geometry so the isolation change cannot silently alter
/// rendering. Xcode 26.x accepts these calls against the isolated conformers
/// too, so the suite is a geometry pin, not a toolchain-independent guard.
nonisolated struct ShapeIsolationTests {
    private static let tolerance: CGFloat = 0.01

    // MARK: - IntentLogo

    @Test func intentLogoScalesWithItsRect() {
        let small = IntentLogo().path(in: CGRect(x: 0, y: 0, width: 24, height: 24)).boundingRect
        let large = IntentLogo().path(in: CGRect(x: 0, y: 0, width: 48, height: 48)).boundingRect
        #expect(!small.isEmpty)
        #expect(abs(large.width - small.width * 2) < Self.tolerance)
        #expect(abs(large.height - small.height * 2) < Self.tolerance)
        #expect(abs(large.minX - small.minX * 2) < Self.tolerance)
        #expect(abs(large.minY - small.minY * 2) < Self.tolerance)
    }

    @Test func intentLogoStaysWithinItsStrokedArtBounds() {
        let rect = CGRect(x: 0, y: 0, width: 24, height: 24)
        let bounds = IntentLogo().path(in: rect).boundingRect
        #expect(rect.insetBy(dx: -1.5, dy: -1.5).contains(bounds))
        #expect(bounds.width > 20)
        #expect(bounds.height > 20)
    }
}
