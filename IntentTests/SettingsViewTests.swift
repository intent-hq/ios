@testable import Intent
import SwiftUI
import Testing

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
