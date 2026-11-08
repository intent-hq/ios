import ActivityKit
import SwiftUI
import WidgetKit

@main
struct IntentWidgetsBundle: WidgetBundle {
    var body: some Widget {
        AgentLiveActivityWidget()
    }
}

struct AgentLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AgentActivityAttributes.self) { context in
            AgentActivityLockScreenView(state: context.state, isStale: context.isStale)
                .activitySystemActionForegroundColor(.primary)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        AgentActivityMark(tint: state.leadingPhase.color)
                            .frame(width: 16, height: 16)
                        Text(state.headline)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(state.rows) { row in
                            AgentActivityRowLink(row: row) {
                                AgentActivityRowView(row: row, showsDetail: false)
                            }
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.top, 4)
                }
            } compactLeading: {
                AgentActivityMark(tint: state.leadingPhase.color)
                    .frame(width: 16, height: 16)
            } compactTrailing: {
                AgentActivityCompactCount(state: state)
            } minimal: {
                AgentActivityMark(tint: state.leadingPhase.color)
                    .frame(width: 14, height: 14)
            }
            .widgetURL(state.firstLinkURL)
            .keylineTint(state.leadingPhase.color)
        }
    }
}
