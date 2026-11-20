import Foundation

enum ConnectionRegistryReadError: Error, Equatable {
    case malformed
    case migrationSaveFailed
    case unavailable(Int32)
}

enum ConnectionRegistryReadResult: Equatable {
    case failed(ConnectionRegistryReadError)
    case loaded([StoredConnection])
    case missing

    // swiftlint:disable:next discouraged_optional_collection
    var connections: [StoredConnection]? {
        switch self {
        case .missing: []
        case .loaded(let connections): connections
        case .failed: nil
        }
    }

    var error: ConnectionRegistryReadError? {
        guard case .failed(let error) = self else { return nil }
        return error
    }
}
