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
            Self.dynamicIsland(for: context.state)
        }
    }

    private static func dynamicIsland(for state: AgentActivityAttributes.ContentState) -> DynamicIsland {
        DynamicIsland {
            DynamicIslandExpandedRegion(.leading) {
                AgentActivityExpandedHeadline(state: state)
            }
            DynamicIslandExpandedRegion(.bottom) {
                AgentActivityExpandedRows(state: state)
            }
        } compactLeading: {
            AgentActivityMark(tint: state.leadingPhase.color)
                .frame(width: AgentActivityStyle.markSize, height: AgentActivityStyle.markSize)
        } compactTrailing: {
            AgentActivityCompactCount(state: state)
        } minimal: {
            AgentActivityMark(tint: state.leadingPhase.color)
                .frame(width: AgentActivityStyle.minimalMarkSize, height: AgentActivityStyle.minimalMarkSize)
        }
        .widgetURL(state.firstLinkURL)
        .keylineTint(state.leadingPhase.color)
    }
}
