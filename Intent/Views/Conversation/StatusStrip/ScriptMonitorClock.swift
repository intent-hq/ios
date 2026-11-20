import SwiftUI

extension EnvironmentValues {
    @Entry var scriptMonitorPresentationDate: Date?
}

struct ScriptMonitorClock<Content: View>: View {
    @Environment(\.scriptMonitorPresentationDate) private var fixedDate
    @Environment(\.scenePhase) private var scenePhase
    @ViewBuilder let content: (Date) -> Content

    var body: some View {
        if let fixedDate {
            content(fixedDate)
        } else {
            TimelineView(.animation(minimumInterval: 1, paused: scenePhase != .active)) { context in
                content(context.date)
            }
        }
    }
}
