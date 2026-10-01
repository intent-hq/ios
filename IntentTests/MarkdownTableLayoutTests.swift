import SwiftUI
import Testing
import UIKit

@testable import Intent

extension MarkdownTextViewTests {
    /// Layout owns readability; the UI suite separately owns gesture routing in the transcript.
    @MainActor
    @Test func wideTableKeepsReadableCellsAcrossWidthsAndTextSizes() async throws {
        for category in [DynamicTypeSize.large, .accessibility3, .accessibility5] {
            for width: CGFloat in [320, 375, 667] {
                let view = ScrollView {
                    MarkdownTextView(text: DemoDesignFixtures.comparisonTable)
                        .padding(.horizontal, 16)
                }
                .environment(\.dynamicTypeSize, category)
                try await SyntheticBadgeHost.render(view, width: width, height: 900) { host, _ in
                    let elements = SyntheticBadgeHost.accessibilityElements(in: host)
                    let setup = try #require(elements.first { $0.accessibilityLabel == "Setup" })
                    let percentage = try #require(elements.first { $0.accessibilityLabel == "62.2%" })
                    let time = try #require(elements.first { $0.accessibilityLabel == "4.9 min" })
                    let description = try #require(elements.first { element in
                        element.accessibilityLabel?.hasPrefix("Baseline with descriptive") == true
                    })
                    let scale = UIFontMetrics(forTextStyle: .body).scaledValue(
                        for: 1, compatibleWith: UITraitCollection(preferredContentSizeCategory: category.uiCategory)
                    )
                    print("TABLE width=\(width) category=\(category) setup=\(setup.accessibilityFrame) percentage=\(percentage.accessibilityFrame) description=\(description.accessibilityFrame)")
                    // Single-word headers and short numeric values must fit on one line.
                    #expect(setup.accessibilityFrame.height < 30 * scale)
                    #expect(percentage.accessibilityFrame.height < 30 * scale)
                    #expect(time.accessibilityFrame.height < 30 * scale)
                    #expect(description.accessibilityFrame.width >= 140 * scale)
                    #expect(description.accessibilityFrame.width <= 300 * scale)
                    #expect(description.accessibilityFrame.height < 200 * scale)
                    #expect(setup.accessibilityFrame.maxY <= description.accessibilityFrame.minY)
                    let horizontal = tableScrollViews(in: host).filter { $0.contentSize.width > $0.bounds.width + 1 }
                    #expect(horizontal.count == 1)
                    if let scroll = horizontal.first {
                        #expect(scroll.bounds.width <= width)
                        #expect(scroll.contentSize.height <= scroll.bounds.height + 1)
                    }
                }
            }
        }
    }

    @MainActor
    @Test func smallTableAndProseStayWithinTheViewport() async throws {
        let view = MarkdownTextView(text: """
        Prose before the table wraps normally within the available space.

        | Metric | Value |
        | :--- | ---: |
        | Count | 12 |

        Prose after the table remains readable.
        """)
        try await SyntheticBadgeHost.render(view, width: 320, height: 600) { host, _ in
            let elements = SyntheticBadgeHost.accessibilityElements(in: host)
            for label in ["Metric", "Value", "Count", "12", "Prose after the table remains readable."] {
                let element = try #require(elements.first { $0.accessibilityLabel == label })
                #expect(element.accessibilityFrame.width <= 320)
            }
            let metric = try #require(elements.first { $0.accessibilityLabel == "Metric" })
            let count = try #require(elements.first { $0.accessibilityLabel == "Count" })
            let value = try #require(elements.first { $0.accessibilityLabel == "Value" })
            let number = try #require(elements.first { $0.accessibilityLabel == "12" })
            #expect(abs(metric.accessibilityFrame.minX - count.accessibilityFrame.minX) < 1)
            #expect(abs(value.accessibilityFrame.maxX - number.accessibilityFrame.maxX) < 1)
            #expect(tableScrollViews(in: host).allSatisfy { $0.contentSize.width <= $0.bounds.width + 1 })
        }
    }

    @MainActor
    private func tableScrollViews(in view: UIView) -> [UIScrollView] {
        ((view as? UIScrollView).map { [$0] } ?? [])
            + view.subviews.flatMap { tableScrollViews(in: $0) }
    }
}

private extension DynamicTypeSize {
    var uiCategory: UIContentSizeCategory {
        switch self {
        case .accessibility3: .accessibilityExtraLarge
        case .accessibility5: .accessibilityExtraExtraExtraLarge
        default: .large
        }
    }
}
