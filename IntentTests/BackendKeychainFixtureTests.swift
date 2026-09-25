import Foundation
import Testing

struct BackendKeychainFixtureTests {
    private let sha256Length = 64
    private typealias Fixtures = BackendKeychainFixtures

    @Test func loadsNonemptyBundledCorpus() throws {
        let fixtures = try Fixtures.bundled()
        for group in Fixtures.caseGroups {
            #expect(try !fixtures.cases(group).isEmpty, "\(group)")
        }
    }

    @Test func missingResourcesFail() throws {
        let resources = try bundledResources()
        for path in Fixtures.resourcePaths {
            #expect(throws: CocoaError.self) {
                _ = try Fixtures { name in
                    guard name != path, let data = resources[name] else { throw CocoaError(.fileNoSuchFile) }
                    return data
                }
            }
        }
    }

    @Test func alteredCorpusManifestAndLockHashesFail() throws {
        let resources = try bundledResources()
        for path in Fixtures.resourcePaths {
            var damaged = resources
            if path == Fixtures.resourcePaths[0] {
                var lock = try Fixtures.object(#require(resources[path]))
                lock["corpusSha256"] = String(repeating: "0", count: sha256Length)
                damaged[path] = try Fixtures.json(lock)
            } else {
                var data = try #require(resources[path])
                data.append(Data("\n".utf8))
                damaged[path] = data
            }
            #expect(throws: BackendKeychainFixtureError.self) { _ = try load(damaged) }
        }
    }

    @Test func emptyCaseGroupsFailEvenWithMatchingHashes() throws {
        let resources = try bundledResources()
        for group in Fixtures.caseGroups {
            var damaged = resources
            var corpus = try Fixtures.object(#require(resources[Fixtures.resourcePaths[1]]))
            corpus[group] = [] as [Fixtures.Object]
            let data = try Fixtures.json(corpus)
            damaged[Fixtures.resourcePaths[1]] = data
            let digest = Fixtures.sha256(data)
            var manifest = try Fixtures.object(#require(resources[Fixtures.resourcePaths[2]]))
            manifest["files"] = ["corpus.json": digest]
            let manifestData = try Fixtures.json(manifest)
            damaged[Fixtures.resourcePaths[2]] = manifestData
            var lock = try Fixtures.object(#require(resources[Fixtures.resourcePaths[0]]))
            lock["corpusSha256"] = digest
            lock["files"] = ["corpus.json": digest, "manifest.json": Fixtures.sha256(manifestData)]
            damaged[Fixtures.resourcePaths[0]] = try Fixtures.json(lock)
            #expect(throws: BackendKeychainFixtureError.self) { _ = try load(damaged) }
        }
    }

    private func bundledResources() throws -> [String: Data] {
        let root = try TestSourceInputs.url(for: "IntentTests/Fixtures")
        return try Dictionary(uniqueKeysWithValues: Fixtures.resourcePaths.map {
            ($0, try Data(contentsOf: root.appendingPathComponent($0)))
        })
    }

    private func load(_ resources: [String: Data]) throws -> Fixtures {
        try Fixtures { path in
            guard let data = resources[path] else { throw CocoaError(.fileNoSuchFile) }
            return data
        }
    }
}
