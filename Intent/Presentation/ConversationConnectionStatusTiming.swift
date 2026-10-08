import Foundation

/// A phase can be a transcript stage or a daemon startup phase. Progress resets
/// only the idle clock; elapsed time always uses the conversation's start date.
struct ConversationConnectionStatusTiming<Phase: Equatable> {
    let startedAt: Date
    private var phase: Phase
    private var lastProgressAt: Date

    init(phase: Phase, startedAt: Date) {
        self.phase = phase
        self.startedAt = startedAt
        lastProgressAt = startedAt
    }

    mutating func update(phase: Phase, at date: Date) {
        guard phase != self.phase else { return }
        self.phase = phase
        lastProgressAt = date
    }

    func elapsed(at date: Date) -> Duration {
        .seconds(max(0, date.timeIntervalSince(startedAt)))
    }

    func showsProgress(at date: Date) -> Bool {
        date.timeIntervalSince(startedAt) >= Constants.Conversation.Column.Loading.statusThreshold
    }

    func isDelayed(phase: Phase, at date: Date) -> Bool {
        // Hide immediately on a new input, before SwiftUI delivers onChange.
        phase == self.phase
            && date.timeIntervalSince(lastProgressAt) >= Constants.Conversation.Column.Loading.slowThreshold
    }
}
