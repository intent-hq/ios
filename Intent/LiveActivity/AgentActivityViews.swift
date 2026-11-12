#if os(iOS)
import SwiftUI

/// Live Activity metrics and colors, shared by the widget extension and the
/// app.
enum AgentActivityStyle {
    static let markSize: CGFloat = 16
    static let minimalMarkSize: CGFloat = 14
    static let headerSpacing: CGFloat = 8
    static let sectionSpacing: CGFloat = 10
    static let rowSpacing: CGFloat = 8
    static let compactRowSpacing: CGFloat = 6
    static let rowTextSpacing: CGFloat = 1
    static let dotSize: CGFloat = 8
    static let dotBaselineOffset: CGFloat = 1
    static let contentPadding: CGFloat = 16
    static let islandInset: CGFloat = 4
    static let staleOpacity = 0.6

    private static let runningRGB: UInt32 = 0xDDEC61
    private static let byteMask: UInt32 = 0xFF
    private static let redShift: UInt32 = 16
    private static let greenShift: UInt32 = 8

    /// The workspace list's running dot.
    static let running = color(runningRGB)

    private static func color(_ rgb: UInt32) -> Color {
        let channel = { (shift: UInt32) in Double((rgb >> shift) & byteMask) / Double(byteMask) }
        return Color(red: channel(redShift), green: channel(greenShift), blue: channel(0))
    }
}

extension AgentActivityAttributes.ContentState {
    var headline: String { "\(runningCount) running" }

    var firstLinkURL: URL? {
        rows.lazy.compactMap { $0.link?.url }.first
    }
}

struct AgentActivityMark: View {
    var tint: Color?

    var body: some View {
        Image(.intentDandelion)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .foregroundStyle(tint ?? .primary)
            .accessibilityHidden(true)
    }
}

struct AgentActivityLockScreenView: View {
    let state: AgentActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: AgentActivityStyle.sectionSpacing) {
            HStack(spacing: AgentActivityStyle.headerSpacing) {
                AgentActivityMark()
                    .frame(width: AgentActivityStyle.markSize, height: AgentActivityStyle.markSize)
                Text(state.headline)
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: AgentActivityStyle.headerSpacing)
                if isStale {
                    Text("Updated \(state.updatedDate, style: .time)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: AgentActivityStyle.rowSpacing) {
                ForEach(state.rows) { row in
                    AgentActivityRowLink(row: row) {
                        AgentActivityRowView(row: row, showsDetail: true)
                    }
                }
            }
        }
        .padding(AgentActivityStyle.contentPadding)
        .opacity(isStale ? AgentActivityStyle.staleOpacity : 1)
    }
}

struct AgentActivityRowView: View {
    let row: AgentActivityRow
    let showsDetail: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: AgentActivityStyle.rowSpacing) {
            Circle()
                .fill(AgentActivityStyle.running)
                .frame(width: AgentActivityStyle.dotSize, height: AgentActivityStyle.dotSize)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - AgentActivityStyle.dotBaselineOffset }
            VStack(alignment: .leading, spacing: AgentActivityStyle.rowTextSpacing) {
                Text(row.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                if showsDetail, let detail = row.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Wraps a row in a link to its agent when one is known.
struct AgentActivityRowLink<Content: View>: View {
    let row: AgentActivityRow
    @ViewBuilder let content: () -> Content

    var body: some View {
        if let url = row.link?.url {
            Link(destination: url, label: content)
        } else {
            content()
        }
    }
}

struct AgentActivityCompactCount: View {
    let state: AgentActivityAttributes.ContentState

    var body: some View {
        Text("\(state.runningCount)")
            .font(.subheadline.weight(.semibold).monospacedDigit())
            .foregroundStyle(AgentActivityStyle.running)
    }
}

/// Expanded Dynamic Island: the headline on the leading edge, rows below.
struct AgentActivityExpandedHeadline: View {
    let state: AgentActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: AgentActivityStyle.compactRowSpacing) {
            AgentActivityMark(tint: AgentActivityStyle.running)
                .frame(width: AgentActivityStyle.markSize, height: AgentActivityStyle.markSize)
            Text(state.headline)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.leading, AgentActivityStyle.islandInset)
    }
}

struct AgentActivityExpandedRows: View {
    let state: AgentActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: AgentActivityStyle.compactRowSpacing) {
            ForEach(state.rows) { row in
                AgentActivityRowLink(row: row) {
                    AgentActivityRowView(row: row, showsDetail: false)
                }
            }
        }
        .padding(.horizontal, AgentActivityStyle.islandInset)
        .padding(.top, AgentActivityStyle.islandInset)
    }
}
#endif
