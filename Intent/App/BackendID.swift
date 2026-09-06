import Foundation

/// Stable identity of a saved backend across launches: wraps the saved
/// connection's UUID (`StoredConnection.id`). Hashable + Codable so it can
/// serve as a `WindowGroup(for:)` presentation value on visionOS and as a
/// dictionary key in `BackendSessionRegistry`.
struct BackendID: Hashable, Codable, Sendable {
    /// The `StoredConnection.id` of the saved backend.
    let connectionID: UUID

    init(_ connectionID: UUID) {
        self.connectionID = connectionID
    }

    init(connection: StoredConnection) {
        self.connectionID = connection.id
    }
}
