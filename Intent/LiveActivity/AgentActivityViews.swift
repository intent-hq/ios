#if os(iOS)
import SwiftUI

/// Live Activity views, shared by the widget extension and the app's demo
/// preview. Colors mirror the workspace status palette.
extension AgentActivityRow.Phase {
    var color: Color {
        switch self {
        case .needsYou: Color(red: 0xFA / 255, green: 0xA7 / 255, blue: 0x55 / 255)
        case .running: Color(red: 0xDD / 255, green: 0xEC / 255, blue: 0x61 / 255)
        case .failed: Color(red: 0xE8 / 255, green: 0x7F / 255, blue: 0x39 / 255)
        case .done: Color(red: 0x6F / 255, green: 0xA3 / 255, blue: 0x56 / 255)
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
        case (let running, 0): "\(running) running"
        case (0, let needsYou): "\(needsYou) needs you"
        case (let running, let needsYou): "\(running) running · \(needsYou) needs you"
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
        Image("IntentDandelion")
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                AgentActivityMark()
                    .frame(width: 16, height: 16)
                Text(state.headline)
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                if isStale {
                    Text("Updated \(state.updatedAt, style: .time)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(state.rows) { row in
                    AgentActivityRowLink(row: row) {
                        AgentActivityRowView(row: row, showsDetail: true)
                    }
                }
            }
        }
        .padding(16)
        .opacity(isStale ? 0.6 : 1)
    }
}

struct AgentActivityRowView: View {
    let row: AgentActivityRow
    let showsDetail: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle()
                .fill(row.phase.color)
                .frame(width: 8, height: 8)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
            VStack(alignment: .leading, spacing: 1) {
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
            Spacer(minLength: 8)
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
        }
    }
}
#endif
