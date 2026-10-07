import Foundation

/// Ordered transcript-loading steps; the active row can show a more specific message.
enum ConversationConnectionStep: Int, CaseIterable {
    case connecting
    case requesting
    case receiving

    init(stage: ConversationLiveTranscript.LoadingStage) {
        switch stage {
        case .idle, .connecting: self = .connecting
        case .requesting, .retrying: self = .requesting
        case .receiving: self = .receiving
        }
    }

    var title: LocalizedStringResource {
        switch self {
        case .connecting: "Connecting to the daemon"
        case .requesting: "Asking the daemon"
        case .receiving: "Receiving messages"
        }
    }
}
