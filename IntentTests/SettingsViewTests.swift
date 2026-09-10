import SwiftUI
import Testing
@testable import Intent

struct SettingsViewTests {
    @Test func connectionSummaryStaysHorizontalAtStandardTextSizes() {
        #expect(!SettingsView.stacksConnectionSummary(for: .large))
        #expect(!SettingsView.stacksConnectionSummary(for: .xxxLarge))
    }

    @Test func connectionSummaryStacksAtAccessibilityTextSizes() {
        #expect(SettingsView.stacksConnectionSummary(for: .accessibility1))
        #expect(SettingsView.stacksConnectionSummary(for: .accessibility5))
    }
}