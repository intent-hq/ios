@testable import Intent
import SwiftUI
import Testing

nonisolated struct ShapeIsolationTests {
    private static let tolerance: CGFloat = 0.01

    @Test func intentLogoScalesWithItsRect() {
        let smallPath = IntentLogo().path(in: CGRect(x: 0, y: 0, width: 24, height: 24))
        let largePath = IntentLogo().path(in: CGRect(x: 0, y: 0, width: 48, height: 48))
        let small = smallPath.cgPath.boundingBoxOfPath
        let large = largePath.cgPath.boundingBoxOfPath
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
