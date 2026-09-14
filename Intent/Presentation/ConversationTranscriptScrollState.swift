import Observation

@Observable
final class ConversationTranscriptScrollState {
    let momentumProxy = ScrollViewMomentumProxy()
    var debounceTask: Task<Void, Never>?
    var userIsScrolledAway = false
    var hasInitiallyScrolled = false
    var initialScrollScheduled = false
    var isScrollingToBottom = false
}
