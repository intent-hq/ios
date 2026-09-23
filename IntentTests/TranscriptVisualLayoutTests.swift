@testable import Intent
import SwiftUI
import Testing
import UIKit

/// Render the actual consumers against their pre-centralization appearance.
/// These fixtures intentionally do not read tokens: a wrong substitution must
/// fail even if the token and the production consumer agree with each other.
@MainActor
struct TranscriptVisualLayoutTests {
    private static let width: CGFloat = 390
    private static let message = "This conversation was interrupted because intentd restarted."

    @Test(arguments: [false, true], [false, true])
    func noticePreservesContrastAndWrapping(dark: Bool, increasedContrast: Bool) throws {
        for textSize in [DynamicTypeSize.large, .accessibility3] {
            let actual = try render(
                SystemNoticeBannerView(message: Self.message),
                textSize: textSize,
                dark: dark,
                increasedContrast: increasedContrast
            )
            let baseline = try render(
                OriginalSystemNotice(message: Self.message),
                textSize: textSize,
                dark: dark,
                increasedContrast: increasedContrast
            )
            try expectSameRendering(actual, baseline)
        }
    }

    @Test(arguments: [CGFloat(1), 2, 3], [false, true])
    func unreadDividerPreservesPixelHairlines(displayScale: CGFloat, dark: Bool) throws {
        for textSize in [DynamicTypeSize.large, .accessibility3] {
            let actual = try render(
                NewMessagesDividerView(), textSize: textSize, dark: dark, displayScale: displayScale
            )
            let baseline = try render(
                OriginalNewMessagesDivider(), textSize: textSize, dark: dark, displayScale: displayScale
            )
            try expectSameRendering(actual, baseline)
        }
    }

    private func expectSameRendering(_ actual: UIImage, _ baseline: UIImage) throws {
        #expect(actual.size == baseline.size)
        let actualPixels = try #require(actual.pngData())
        let baselinePixels = try #require(baseline.pngData())
        #expect(actualPixels == baselinePixels)
    }

    private func render<Content: View>(
        _ content: Content,
        textSize: DynamicTypeSize,
        dark: Bool,
        increasedContrast: Bool = false,
        displayScale: CGFloat = 2
    ) throws -> UIImage {
        // ImageRenderer needs the SDK's writable backing key; colorSchemeContrast is read-only.
        let renderer = ImageRenderer(content: content
            .environment(\.dynamicTypeSize, textSize)
            .environment(\.colorScheme, dark ? .dark : .light)
            .environment(\._colorSchemeContrast, increasedContrast ? .increased : .standard)
            .environment(\.displayScale, displayScale)
            .environment(\.locale, Locale(identifier: "en_US")))
        renderer.scale = displayScale
        renderer.proposedSize = ProposedViewSize(width: Self.width, height: nil)
        return UIImage(cgImage: try #require(renderer.cgImage))
    }
}

private struct OriginalSystemNotice: View {
    let message: String
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    private enum Baseline {
        static let spacing: CGFloat = 10
        static let horizontalPadding: CGFloat = 12
        static let verticalPadding: CGFloat = 10
        static let backgroundOpacity: Double = 0.1
        static let contrastMultiplier: Double = 1.75
        static let cornerRadius: CGFloat = 8
        static let borderOpacity: Double = 0.3
    }

    var body: some View {
        HStack(alignment: .top, spacing: Baseline.spacing) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.subheadline)
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
                .padding(.top, 1)
            Text(message)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.foreground(for: colorScheme))
                .textSelection(.enabled)
        }
        .padding(.horizontal, Baseline.horizontalPadding)
        .padding(.vertical, Baseline.verticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(contrast == .increased
            ? Baseline.backgroundOpacity * Baseline.contrastMultiplier
            : Baseline.backgroundOpacity))
        .clipShape(RoundedRectangle(cornerRadius: Baseline.cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Baseline.cornerRadius)
                .strokeBorder(
                    Color.orange.opacity(contrast == .increased ? 1 : Baseline.borderOpacity),
                    lineWidth: contrast == .increased ? 1 * 2 : 1
                )
        )
    }
}

private struct OriginalNewMessagesDivider: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale

    private enum Baseline {
        static let spacing: CGFloat = 8
        static let labelSpacing: CGFloat = 6
        static let iconOpacity: Double = 0.7
        static let labelHorizontalPadding: CGFloat = 4
        static let horizontalPadding: CGFloat = 8
        static let verticalPadding: CGFloat = 4
        static let minimumLineWidth: CGFloat = 16
    }

    var body: some View {
        HStack(spacing: Baseline.spacing) {
            hairline
            HStack(spacing: Baseline.labelSpacing) {
                Image(systemName: "envelope")
                    .font(.caption2)
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme).opacity(Baseline.iconOpacity))
                Text("New messages")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.foreground(for: colorScheme))
                    .lineLimit(1)
            }
            .padding(.horizontal, Baseline.labelHorizontalPadding)
            .layoutPriority(1)
            hairline
        }
        .padding(.horizontal, Baseline.horizontalPadding)
        .padding(.vertical, Baseline.verticalPadding)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("New messages")
    }

    private var hairline: some View {
        Rectangle()
            .fill(Theme.border(for: colorScheme))
            .frame(height: 1 / max(displayScale, 1))
            .frame(minWidth: Baseline.minimumLineWidth, maxWidth: .infinity)
    }
}
