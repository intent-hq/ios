import CryptoKit
import Foundation

enum BackendKeychainFixtureError: Error {
    case invalid(String)
}

/// Offline, exact-byte mirror of the monorepo contract. CI also compares it
/// with the canonical Git revision; these checks protect native bundle inputs.
struct BackendKeychainFixtures {
    typealias Object = [String: Any]

    static let caseGroups = [
        "parseCases", "identityCases", "expiryCases", "iosPublishCases", "iosImportCases", "noWriteCases"
    ]
    static let resourcePaths = [
        "backend-keychain.lock.json", "backend-keychain/v1/corpus.json", "backend-keychain/v1/manifest.json"
    ]
    let corpus: Object
    let sourceCommit: String
    let corpusSha256: String

    static func bundled() throws -> Self {
        let root = try TestSourceInputs.url(for: "IntentTests/Fixtures")
        let fixtures = try Self { try Data(contentsOf: root.appendingPathComponent($0)) }
        print("Backend Keychain fixtures: intent-hq/intent@\(fixtures.sourceCommit) corpus sha256 \(fixtures.corpusSha256)")
        return fixtures
    }

    init(read: (String) throws -> Data) throws {
        let lock = try Self.object(read(Self.resourcePaths[0]))
        let corpusData = try read(Self.resourcePaths[1])
        let manifestData = try read(Self.resourcePaths[2])
        let manifest = try Self.object(manifestData)
        let files: [String: String] = try Self.value("files", in: lock)
        let manifestFiles: [String: String] = try Self.value("files", in: manifest)
        let revision: String = try Self.value("sourceCommit", in: lock)
        let digest: String = try Self.value("corpusSha256", in: lock)
        guard lock["lockVersion"] as? Int == 1,
              lock["sourceRepository"] as? String == "intent-hq/intent",
              lock["sourcePath"] as? String == "docs/protocol/fixtures/backend-keychain/v1",
              revision.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil,
              Set(files.keys) == ["corpus.json", "manifest.json"],
              digest == Self.sha256(corpusData),
              files["corpus.json"] == digest,
              files["manifest.json"] == Self.sha256(manifestData),
              manifestFiles == ["corpus.json": digest],
              manifest["fixtureFormatVersion"] as? Int == 1,
              manifest["payloadVersion"] as? Int == 1
        else { throw BackendKeychainFixtureError.invalid("fixture lock, manifest or SHA-256 mismatch") }
        let corpus = try Self.object(corpusData)
        guard corpus["fixtureFormatVersion"] as? Int == 1, corpus["payloadVersion"] as? Int == 1 else {
            throw BackendKeychainFixtureError.invalid("unsupported fixture format or payload version")
        }
        self.corpus = corpus
        sourceCommit = revision
        corpusSha256 = digest
        for group in Self.caseGroups {
            let cases = try cases(group)
            let identifiers: [String] = try cases.map { try Self.value("id", in: $0) }
            guard !cases.isEmpty, identifiers.allSatisfy({ !$0.isEmpty }), Set(identifiers).count == cases.count else {
                throw BackendKeychainFixtureError.invalid("\(group) must have nonempty, unique conformance cases")
            }
        }
        for group in ["expiryCases", "iosImportCases", "noWriteCases"] {
            for fixture in try cases(group) {
                _ = try parseCase(Self.value("parseCaseId", in: fixture))
            }
        }
    }

    func cases(_ name: String) throws -> [Object] {
        try Self.value(name, in: corpus)
    }

    func parseCase(_ id: String) throws -> Object {
        guard let fixture = try cases("parseCases").first(where: { $0["id"] as? String == id }) else {
            throw BackendKeychainFixtureError.invalid("unknown parse case \(id)")
        }
        return fixture
    }

    static func value<Value>(_ key: String, in object: Object) throws -> Value {
        guard let value = object[key] as? Value else {
            throw BackendKeychainFixtureError.invalid("missing or invalid \(key)")
        }
        return value
    }

    static func nullable<Value>(_ key: String, in object: Object) throws -> Value? {
        if object[key] is NSNull { return nil }
        return try value(key, in: object)
    }

    static func object(_ data: Data) throws -> Object {
        guard let object = try JSONSerialization.jsonObject(with: data) as? Object else {
            throw BackendKeychainFixtureError.invalid("fixture JSON must be an object")
        }
        return object
    }

    static func json(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
