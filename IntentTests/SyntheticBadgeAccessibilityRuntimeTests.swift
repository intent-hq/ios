import Foundation
import SwiftUI
import Testing
import UIKit

extension SyntheticBadgeHostTests {
    @MainActor private final class AutomationFixture {
        var value: Int32 = 0
        var writes: [Int32] = []
        var loads = 0
        var closes = 0
        var acceptsWrites = true

        func load() -> SyntheticBadgeAccessibilityRuntime.Interface {
            loads += 1
            return .init(
                read: { self.value },
                write: { value in
                    self.writes.append(value)
                    if self.acceptsWrites { self.value = value }
                },
                close: { self.closes += 1 }
            )
        }
    }

    @Test(arguments: [Int32(0), Int32(1)], [false, true]) @MainActor
    func overlappingAccessibilityHostsRestoreTheOriginalModeOnlyOnFinalRelease(original: Int32, nested: Bool) throws {
        let fixture = AutomationFixture()
        fixture.value = original
        let runtime = SyntheticBadgeAccessibilityRuntime(load: fixture.load)
        let first = try runtime.acquire()
        let second = try runtime.acquire()
        #expect(fixture.value == 1 && fixture.loads == 1)
        let earlierRelease = nested ? second : first
        let finalRelease = nested ? first : second
        runtime.release(earlierRelease)
        runtime.release(earlierRelease)
        #expect(fixture.value == 1 && fixture.closes == 0)
        runtime.release(finalRelease)
        #expect(fixture.value == original && fixture.closes == 1)
        #expect(fixture.writes == [1, original])
        runtime.release(finalRelease)
        #expect(fixture.closes == 1)
    }

    @Test @MainActor func staleAccessibilityReleaseCannotDisableANewerHost() throws {
        let fixture = AutomationFixture()
        let runtime = SyntheticBadgeAccessibilityRuntime(load: fixture.load)
        let old = try runtime.acquire()
        runtime.release(old)
        let current = try runtime.acquire()
        runtime.release(old)
        #expect(fixture.value == 1 && fixture.closes == 1)
        runtime.release(current)
        #expect(fixture.value == 0 && fixture.closes == 2)
    }

    @Test @MainActor func failedAccessibilityActivationRestoresAndClosesBeforeRetry() throws {
        let fixture = AutomationFixture()
        fixture.acceptsWrites = false
        let runtime = SyntheticBadgeAccessibilityRuntime(load: fixture.load)
        #expect(throws: SyntheticBadgeAccessibilityRuntime.RuntimeError.activationFailed) { try runtime.acquire() }
        #expect(fixture.writes == [1, 0] && fixture.closes == 1)
        fixture.acceptsWrites = true
        let token = try runtime.acquire()
        #expect(fixture.value == 1 && fixture.loads == 2)
        runtime.release(token)
        #expect(fixture.value == 0 && fixture.closes == 2)
    }

    @Test(arguments: [false, true]) @MainActor
    func unavailableAccessibilityRuntimeFailsWithoutAllocatingOwnership(missingSymbols: Bool) throws {
        let fixture = AutomationFixture()
        var available = false
        let failure: SyntheticBadgeAccessibilityRuntime.RuntimeError = missingSymbols ? .symbolsUnavailable : .libraryUnavailable
        let runtime = SyntheticBadgeAccessibilityRuntime {
            guard available else { throw failure }
            return fixture.load()
        }
        #expect(throws: failure) { try runtime.acquire() }
        #expect(fixture.loads == 0 && fixture.writes.isEmpty && fixture.closes == 0)
        available = true
        let token = try runtime.acquire()
        runtime.release(token)
        #expect(fixture.loads == 1 && fixture.value == 0 && fixture.closes == 1)
    }

    @Test @MainActor func hostedSwiftUIPrimitivePublishesActualAccessibility() async throws {
        let identifier = "syntheticHost.actualButton"
        try await SyntheticBadgeHost.render(
            Button("Published button") {}.accessibilityIdentifier(identifier).accessibilityValue("Ready"),
            width: 200,
            height: 100
        ) { host, window in
            let elements = SyntheticBadgeHost.accessibilityElements(in: host)
            let element = try #require(elements.first { SyntheticBadgeHost.accessibilityIdentifier(of: $0) == identifier })
            #expect(element.accessibilityLabel == "Published button")
            #expect(element.accessibilityValue == "Ready")
            #expect(element.accessibilityTraits.contains(.button))
            #expect(element.accessibilityFrame.width > 0 && element.accessibilityFrame.height > 0)
            #expect(window.convert(window.bounds, to: nil).contains(element.accessibilityFrame))
        }
    }
}
