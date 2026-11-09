import SwiftUI

/// Owned by the conversation, so moving a row between lazy history and the
/// eager tail does not reset the reader's disclosure choices.
@MainActor
final class TranscriptDisclosureStore {
    private var rows: [String: TranscriptDisclosureState] = [:]

    func state(for messageID: String) -> TranscriptDisclosureState {
        if let state = rows[messageID] { return state }
        let state = TranscriptDisclosureState()
        rows[messageID] = state
        return state
    }

    func retainMessages(withIDs messageIDs: Set<String>) {
        rows = rows.filter { messageIDs.contains($0.key) }
    }
}

@MainActor @Observable
final class TranscriptDisclosureState {
    enum DisclosureKey: Hashable {
        case agentMessage
        case automatedWake
        case attentionNotice
        case tool(String)
        case toolInput(String)
        case thinking(String)
        case group(String)
    }

    var values: [DisclosureKey: Bool] = [:]
}

extension EnvironmentValues {
    @Entry var transcriptDisclosureState: TranscriptDisclosureState?
}

/// Standalone previews and non-transcript callers still get local state.
struct TranscriptDisclosure: DynamicProperty {
    @Environment(\.transcriptDisclosureState) private var retained
    @State private var local: [TranscriptDisclosureState.DisclosureKey: Bool] = [:]

    func binding(for key: TranscriptDisclosureState.DisclosureKey, default defaultValue: Bool = false) -> Binding<Bool> {
        Binding(
            get: { retained?.values[key] ?? local[key] ?? defaultValue },
            set: { value in
                if let retained { retained.values[key] = value } else { local[key] = value }
            }
        )
    }

    func initialize(_ key: TranscriptDisclosureState.DisclosureKey, default defaultValue: Bool) {
        if let retained {
            if retained.values[key] == nil { retained.values[key] = defaultValue }
        } else if local[key] == nil {
            local[key] = defaultValue
        }
    }
}
