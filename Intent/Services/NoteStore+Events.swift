import Foundation

extension NoteStore {
    func noteChanges() -> AsyncStream<Void> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(
            of: Void.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        noteChangeContinuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.noteChangeContinuations[id] = nil
            }
        }
        return stream
    }

    nonisolated static let handledChannels = ["note:"]
    nonisolated static let refetchEventTypes: Set<String> = [
        "note:created", "note:updated", "note:deleted"
    ]
    nonisolated static let ignoredEventTypes: Set<String> = ["note:presence"]

    // Optional payload presence is part of the shared classification contract.
    // swiftlint:disable:next discouraged_optional_collection
    nonisolated static func classify(type: String, data _: [String: Any]?) -> EventClassification? {
        if refetchEventTypes.contains(type) { return .refetch }
        if ignoredEventTypes.contains(type) { return .ignore }
        return nil
    }

    // swiftlint:disable:next discouraged_optional_collection
    nonisolated static func event(from params: Any) -> [String: Any]? {
        guard let dictionary = params as? [String: Any] else { return nil }
        return dictionary["event"] as? [String: Any] ?? dictionary
    }
}
