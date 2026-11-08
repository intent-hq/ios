#if os(iOS)
import SwiftUI

/// Live Activity metrics and colors, shared by the widget extension and the
/// app. Colors mirror the workspace status palette.
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

    private static let needsYouRGB: UInt32 = 0xFAA755
    private static let runningRGB: UInt32 = 0xDDEC61
    private static let failedRGB: UInt32 = 0xE87F39
    private static let doneRGB: UInt32 = 0x6FA356
    private static let byteMask: UInt32 = 0xFF
    private static let redShift: UInt32 = 16
    private static let greenShift: UInt32 = 8

    static let needsYou = color(needsYouRGB)
    static let running = color(runningRGB)
    static let failed = color(failedRGB)
    static let done = color(doneRGB)

    private static func color(_ rgb: UInt32) -> Color {
        let channel = { (shift: UInt32) in Double((rgb >> shift) & byteMask) / Double(byteMask) }
        return Color(red: channel(redShift), green: channel(greenShift), blue: channel(0))
    }
}

extension AgentActivityRow.Phase {
    var color: Color {
        switch self {
        case .needsYou: AgentActivityStyle.needsYou
        case .running: AgentActivityStyle.running
        case .failed: AgentActivityStyle.failed
        case .done: AgentActivityStyle.done
        }
    }

    var label: String {
        switch self {
        case .needsYou: "Needs you"
        case .running: "Working"
        case .failed: "Failed"
        case .done: "Done"
        }
    }
}

extension AgentActivityAttributes.ContentState {
    var headline: String {
        switch (runningCount, needsYouCount) {
        case (0, 0): "All done"
        case let (running, 0): "\(running) running"
        case let (0, needsYou): "\(needsYou) needs you"
        case let (running, needsYou): "\(running) running · \(needsYou) needs you"
        }
    }

    /// The phase that colors the compact Dynamic Island.
    var leadingPhase: AgentActivityRow.Phase {
        if needsYouCount > 0 { return .needsYou }
        if runningCount > 0 { return .running }
        return rows.first?.phase ?? .done
    }

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
                    Text("Updated \(state.updatedAt, style: .time)")
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
                .fill(row.phase.color)
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
            Spacer(minLength: AgentActivityStyle.rowSpacing)
            Text(row.phase.label)
                .font(.caption.weight(row.phase == .needsYou ? .semibold : .regular))
                .foregroundStyle(row.phase == .needsYou ? .primary : .secondary)
                .fixedSize()
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
        let count = state.needsYouCount > 0 ? state.needsYouCount : state.runningCount
        if count > 0 {
            Text("\(count)")
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(state.leadingPhase.color)
        } else {
            Image(systemName: "checkmark")
                .font(.caption.weight(.bold))
                .foregroundStyle(AgentActivityRow.Phase.done.color)
                .accessibilityLabel("All done")
        }
    }
}

/// Expanded Dynamic Island: the headline on the leading edge, rows below.
struct AgentActivityExpandedHeadline: View {
    let state: AgentActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: AgentActivityStyle.compactRowSpacing) {
            AgentActivityMark(tint: state.leadingPhase.color)
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
