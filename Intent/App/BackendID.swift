import Foundation

nonisolated struct BackendID: Hashable, Codable, Sendable {
    let connectionID: UUID

    init(_ connectionID: UUID) {
        self.connectionID = connectionID
    }

    init(connection: StoredConnection) {
        self.connectionID = connection.id
    }
}
