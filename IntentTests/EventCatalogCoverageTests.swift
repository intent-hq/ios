import Foundation
import Testing
@testable import Intent

/// Every event type intentd can emit on a channel a store consumes must be a
/// deliberate decision in that store's classification tables. The catalog is
/// the vendored intentd golden `IntentTests/Fixtures/event_types.json`
/// (`crates/intent-core/tests/goldens/event_types.json` in intent-hq/intentd);
/// re-vendor it when the daemon adds a type, then classify the new type.
struct EventCatalogCoverageTests {

    // MARK: - Golden

    private struct Golden: Decodable {
        struct Discriminator: Decodable {
            let path: String
            let kind: String
            let values: [String]
            let absent: String?
        }
        let version: Int
        let types: [String]
        let discriminators: [String: Discriminator]
    }

    private final class BundleLocator {}

    private static let golden: Golden = {
        let bundle = Bundle(for: BundleLocator.self)
        let url = bundle.url(forResource: "event_types", withExtension: "json")
            ?? bundle.url(forResource: "event_types", withExtension: "json", subdirectory: "Fixtures")
        guard let url else {
            fatalError("IntentTests/Fixtures/event_types.json is not in the test bundle")
        }
        do {
            return try JSONDecoder().decode(Golden.self, from: Data(contentsOf: url))
        } catch {
            fatalError("Failed to decode event_types.json: \(error)")
        }
    }()

    @Test func goldenIsWellFormed() {
        let g = Self.golden
        #expect(g.version == 1)
        #expect(!g.types.isEmpty)
        #expect(g.types == g.types.sorted(), "golden types must be sorted")
        #expect(Set(g.types).count == g.types.count, "golden types must be unique")
        for (type, d) in g.discriminators {
            #expect(g.types.contains(type), "discriminator for unknown type \(type)")
            #expect(d.kind == "value" || d.kind == "keys", "\(type): unknown discriminator kind \(d.kind)")
            #expect(!d.values.isEmpty, "\(type): discriminator has no values")
        }
    }

    // MARK: - Store tables

    private struct StoreTables {
        let name: String
        let channels: [String]
        let refetch: Set<String>
        let patchInPlace: Set<String>
        let ignore: Set<String>
        /// Per discriminated type: the discriminator values the store's
        /// table names (golden `values`; the `absent` case is checked by
        /// classifying without the path present).
        let discriminatorValues: [String: Set<String>]
        /// Per discriminated type: the classification each golden value
        /// (and the `absent` shape) must produce. Spelled out here rather
        /// than read from the store's table so a flipped table entry fails.
        let discriminatorExpectations: [String: DiscriminatorExpectation]
        let classify: (String, [String: Any]?) -> EventClassification?
    }

    private struct DiscriminatorExpectation {
        let values: [String: EventClassification]
        let absent: EventClassification
    }

    /// `task:ready-tasks-changed`: only `note-deleted` signals a row left the
    /// list; `relations-changed` and the reason-less status-change shape are
    /// covered by other events.
    private static let readyTasksChangedExpectation = DiscriminatorExpectation(
        values: ["note-deleted": .refetch, "relations-changed": .ignore],
        absent: .ignore)

    /// `workspace:updated`: only a `lastActivity`-only delta is patched in
    /// place; every other key, and a missing `changes`, refetches.
    private static let workspaceUpdatedExpectation = DiscriminatorExpectation(
        values: [
            "lastActivity": .patchInPlace,
            "activePullRequest": .refetch, "archived": .refetch, "archivedAt": .refetch,
            "attention": .refetch, "autoCommitEnabled": .refetch, "autoUnarchive": .refetch,
            "baseCommitSha": .refetch, "baseRef": .refetch, "branch": .refetch,
            "browserClientId": .refetch, "defaultModel": .refetch, "isRemote": .refetch,
            "mcpServerToggled": .refetch, "path": .refetch, "prNumber": .refetch,
            "prStatus": .refetch, "prUrl": .refetch, "pullRequests": .refetch,
            "repositoryName": .refetch, "repositoryOwner": .refetch,
            "repositoryPath": .refetch, "scope": .refetch, "setupScript": .refetch,
            "skipIsolation": .refetch, "status": .refetch, "statusImageAssetId": .refetch,
            "statusMessage": .refetch, "tags": .refetch, "title": .refetch,
            "worktreePath": .refetch,
        ],
        absent: .refetch)

    private static let stores: [StoreTables] = [
        StoreTables(
            name: "AgentStore", channels: AgentStore.handledChannels,
            refetch: AgentStore.refetchEventTypes, patchInPlace: [],
            ignore: AgentStore.ignoredEventTypes, discriminatorValues: [:],
            discriminatorExpectations: [:],
            classify: AgentStore.classify),
        StoreTables(
            name: "NoteStore", channels: NoteStore.handledChannels,
            refetch: NoteStore.refetchEventTypes, patchInPlace: [],
            ignore: NoteStore.ignoredEventTypes, discriminatorValues: [:],
            discriminatorExpectations: [:],
            classify: NoteStore.classify),
        StoreTables(
            name: "TaskStore", channels: TaskStore.handledChannels,
            refetch: TaskStore.refetchEventTypes, patchInPlace: [],
            ignore: TaskStore.ignoredEventTypes,
            discriminatorValues: [
                "task:ready-tasks-changed": Set(TaskStore.readyTasksChangedReasonClassification.keys),
            ],
            discriminatorExpectations: ["task:ready-tasks-changed": readyTasksChangedExpectation],
            classify: TaskStore.classify),
        StoreTables(
            name: "WorkspaceStore", channels: WorkspaceStore.handledChannels,
            refetch: WorkspaceStore.refetchEventTypes,
            patchInPlace: WorkspaceStore.patchInPlaceEventTypes,
            ignore: WorkspaceStore.ignoredEventTypes,
            discriminatorValues: [
                "workspace:updated": Set(WorkspaceStore.workspaceUpdatedChangeKeyClassification.keys),
            ],
            discriminatorExpectations: ["workspace:updated": workspaceUpdatedExpectation],
            classify: WorkspaceStore.classify),
    ]

    /// Builds an event `data` payload placing `leaf` at the golden's
    /// discriminator `path` (`data.a.b` → `["a": ["b": leaf]]`).
    private static func data(at path: String, leaf: Any) -> [String: Any] {
        var segments = path.split(separator: ".").map(String.init)
        precondition(segments.first == "data", "discriminator path must start with data.")
        segments.removeFirst()
        var value: Any = leaf
        for segment in segments.reversed() {
            value = [segment: value]
        }
        guard let dict = value as? [String: Any] else {
            preconditionFailure("discriminator path \(path) has no segment below data")
        }
        return dict
    }

    /// Every discriminator value (or `changes` key) the golden lists for a
    /// type on the store's channels must be named by that store's table and
    /// classify to the classification this test spells out for it; the
    /// `absent` shape must classify to its expected value too. For `keys`
    /// discriminators a refetch key must dominate a patch-in-place key.
    @Test func everyDiscriminatorValueIsClassified() {
        for store in Self.stores {
            for (type, d) in Self.golden.discriminators
            where store.channels.contains(where: { type.hasPrefix($0) }) {
                guard let named = store.discriminatorValues[type] else {
                    Issue.record("\(store.name) has no discriminator table for \(type)")
                    continue
                }
                guard let expectation = store.discriminatorExpectations[type] else {
                    Issue.record("\(store.name) has no expected classifications for \(type) in this test")
                    continue
                }
                let goldenValues = Set(d.values)
                #expect(named.subtracting(goldenValues).isEmpty,
                        "\(store.name) names \(type) discriminator values not in the catalog: \(named.subtracting(goldenValues))")
                #expect(Set(expectation.values.keys) == goldenValues,
                        "\(store.name) expectations for \(type) must list exactly the catalog's discriminator values; extra: \(Set(expectation.values.keys).subtracting(goldenValues)), missing: \(goldenValues.subtracting(expectation.values.keys))")
                for value in d.values {
                    #expect(named.contains(value),
                            "\(store.name) does not classify \(type) with \(d.path) = \(value)")
                    let payload: [String: Any]
                    switch d.kind {
                    case "value": payload = Self.data(at: d.path, leaf: value)
                    case "keys": payload = Self.data(at: d.path, leaf: [value: "x"])
                    default: Issue.record("\(type): unknown discriminator kind \(d.kind)"); continue
                    }
                    let expected = expectation.values[value]
                    let actual = store.classify(type, payload)
                    #expect(actual != nil,
                            "\(store.name) does not classify \(type) with \(d.path) = \(value)")
                    #expect(actual == expected,
                            "\(store.name) classifies \(type) with \(d.path) = \(value) as \(String(describing: actual)), expected \(String(describing: expected))")
                }
                let absentActual = store.classify(type, [:])
                #expect(absentActual != nil,
                        "\(store.name) does not classify \(type) when \(d.path) is absent")
                #expect(absentActual == expectation.absent,
                        "\(store.name) classifies \(type) with \(d.path) absent as \(String(describing: absentActual)), expected \(expectation.absent)")
                if d.kind == "keys" {
                    let patched = expectation.values.filter { $0.value == .patchInPlace }.keys.sorted()
                    let refetched = expectation.values.filter { $0.value == .refetch }.keys.sorted()
                    for patchKey in patched {
                        for refetchKey in refetched {
                            let payload = Self.data(at: d.path, leaf: [patchKey: "x", refetchKey: "x"])
                            let actual = store.classify(type, payload)
                            #expect(actual == .refetch,
                                    "\(store.name) classifies \(type) with \(d.path) keys [\(patchKey), \(refetchKey)] as \(String(describing: actual)); a refetch key must dominate")
                        }
                    }
                }
            }
            for type in store.discriminatorValues.keys {
                #expect(Self.golden.discriminators[type] != nil,
                        "\(store.name) has a discriminator table for \(type), which the catalog does not discriminate")
            }
            for type in store.discriminatorExpectations.keys {
                #expect(store.discriminatorValues[type] != nil,
                        "\(store.name) has expected classifications for \(type) but no discriminator table")
            }
        }
    }

    /// A store's tables are inert unless `ConnectionManager` subscribes to
    /// the channel globally.
    @Test func globalSubscriptionCoversEveryHandledChannel() {
        for store in Self.stores {
            for channel in store.channels {
                #expect(ConnectionManager.globalEventTypes.contains(channel + "*"),
                        "\(store.name) handles \(channel) but ConnectionManager.globalEventTypes = \(ConnectionManager.globalEventTypes)")
            }
        }
    }

    private static func catalogTypes(on channels: [String]) -> [String] {
        golden.types.filter { type in channels.contains { type.hasPrefix($0) } }
    }

    /// Any type on a handled channel that no table names is a silent drop of
    /// a possibly-rendered change — fail naming the store and the type.
    @Test func everyCatalogTypeOnHandledChannelsIsClassified() {
        for store in Self.stores {
            let types = Self.catalogTypes(on: store.channels)
            #expect(!types.isEmpty, "\(store.name): no catalog types on \(store.channels)")
            for type in types {
                #expect(store.classify(type, nil) != nil,
                        "\(store.name) does not classify \(type)")
            }
        }
    }

    /// A table entry the catalog does not contain is a typo or a type the
    /// daemon no longer emits.
    @Test func everyTableEntryIsInCatalog() {
        let catalog = Set(Self.golden.types)
        for store in Self.stores {
            for type in store.refetch.union(store.patchInPlace).union(store.ignore) {
                #expect(catalog.contains(type),
                        "\(store.name) classifies \(type), which is not in the catalog")
                #expect(store.channels.contains { type.hasPrefix($0) },
                        "\(store.name) classifies \(type) outside its channels \(store.channels)")
            }
        }
    }

    @Test func classificationSetsAreDisjoint() {
        for store in Self.stores {
            #expect(store.refetch.intersection(store.patchInPlace).isEmpty,
                    "\(store.name): refetch ∩ patchInPlace = \(store.refetch.intersection(store.patchInPlace))")
            #expect(store.refetch.intersection(store.ignore).isEmpty,
                    "\(store.name): refetch ∩ ignore = \(store.refetch.intersection(store.ignore))")
            #expect(store.patchInPlace.intersection(store.ignore).isEmpty,
                    "\(store.name): patchInPlace ∩ ignore = \(store.patchInPlace.intersection(store.ignore))")
        }
    }

    @Test func tableEntriesClassifyAsTheirTable() {
        for store in Self.stores {
            for type in store.refetch {
                #expect(store.classify(type, nil) == .refetch, "\(store.name): \(type)")
            }
            for type in store.patchInPlace {
                #expect(store.classify(type, nil) == .patchInPlace, "\(store.name): \(type)")
            }
            for type in store.ignore {
                #expect(store.classify(type, nil) == .ignore, "\(store.name): \(type)")
            }
        }
    }

    @Test func typesOffHandledChannelsAreUnclassified() {
        for store in Self.stores {
            let offChannel = Self.golden.types.filter { type in !store.channels.contains { type.hasPrefix($0) } }
            for type in offChannel {
                #expect(store.classify(type, nil) == nil, "\(store.name) classifies off-channel \(type)")
            }
        }
    }
}
