import Foundation

/// Safe categories only: never carries credential bytes or decoder diagnostics.
enum ConnectionRegistryReadError: Error, Equatable {
    case malformed
    case migrationSaveFailed
    case unavailable(Int32)
}

enum ConnectionRegistryReadResult: Equatable {
    case failed(ConnectionRegistryReadError)
    case loaded([StoredConnection])
    case missing

    // Missing is a known empty baseline; a failed read is never a write baseline.
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
