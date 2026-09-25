import Foundation
import Security
import Testing

@testable import Intent

/// Projects actual production values without normalizing routes or identities.
enum BackendKeychainConformanceSupport {
    typealias Fixtures = BackendKeychainFixtures
    private static let millisecondsPerSecond: Double = 1000

    static func date(_ milliseconds: Double) -> Date {
        Date(timeIntervalSince1970: milliseconds / millisecondsPerSecond)
    }

    static func record(_ record: SyncedBackendRecord) -> Fixtures.Object {
        [
            "label": record.label, "host": record.host, "hosts": record.hosts, "port": record.port,
            "fingerprint": record.fingerprint, "hostname": record.hostname as Any? ?? NSNull(),
            "detectHosts": record.detectHosts, "token": record.token, "updatedAt": record.updatedAt,
            "deleted": record.deleted, "deletedAt": record.deletedAt as Any? ?? NSNull(),
            "tcAddress": record.tcAddress as Any? ?? NSNull()
        ]
    }

    static func connection(_ input: Fixtures.Object) throws -> StoredConnection {
        var connection = try StoredConnection(
            server: PairedServer(
                hosts: Fixtures.value("hosts", in: input),
                port: Fixtures.value("port", in: input),
                name: Fixtures.value("label", in: input),
                pairedAt: date(0),
                certFingerprint: Fixtures.value("fingerprint", in: input),
                tcAddress: Fixtures.nullable("tcAddress", in: input)
            ),
            token: Fixtures.value("token", in: input),
            displayName: Fixtures.value("label", in: input)
        )
        connection.pendingSyncUpdatedAt = try Fixtures.nullable("pendingSyncUpdatedAt", in: input)
        if let pending: Fixtures.Object = try Fixtures.nullable("pendingRoutePublication", in: input) {
            connection.pendingRoutePublication = try JSONDecoder().decode(
                PendingBackendRoutePublication.self, from: Fixtures.json(pending)
            )
        }
        return connection
    }

    static func writes(_ cloud: MemorySyncedKeychain) throws -> [Fixtures.Object] {
        let additions = try cloud.adds.map { attributes in
            try write(query: attributes, attributes: attributes)
        }
        let updates = try cloud.updates.map { try write(query: $0.query, attributes: $0.attributes) }
        return additions + updates
    }

    private static func write(query: Fixtures.Object, attributes: Fixtures.Object) throws -> Fixtures.Object {
        let account: String = try Fixtures.value(kSecAttrAccount as String, in: query)
        let data: Data = try Fixtures.value(kSecValueData as String, in: attributes)
        return ["account": account, "payload": try Fixtures.object(data)]
    }

    static func outcome(_ outcome: SyncedBackendPublisher.Outcome) -> String {
        switch outcome {
        case .published: "published"
        case .retry: "retry"
        case .superseded: "superseded"
        }
    }

    static func expectJSON(_ actual: Any, _ expected: Any, id: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let actualData = try Fixtures.json(actual)
        let expectedData = try Fixtures.json(expected)
        #expect(
            actualData == expectedData,
            "\(id): actual \(String(decoding: actualData, as: UTF8.self)); expected \(String(decoding: expectedData, as: UTF8.self))",
            sourceLocation: sourceLocation
        )
    }
}
