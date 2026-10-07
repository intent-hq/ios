import Foundation

/// Ordered transcript-loading steps; the active row can show a more specific message.
enum ConversationConnectionStep: Int, CaseIterable {
    case connecting = 0
    case receiving = 2
    case requesting = 1

    static let allCases: [Self] = [.connecting, .requesting, .receiving]

    init(stage: ConversationLiveTranscript.LoadingStage) {
        switch stage {
        case .idle, .connecting: self = .connecting
        case .requesting, .retrying: self = .requesting
        case .receiving: self = .receiving
        }
    }

    var title: LocalizedStringResource {
        switch self {
        case .connecting: "Connecting"
        case .requesting: "Requesting messages"
        case .receiving: "Receiving messages"
        }
    }
}
