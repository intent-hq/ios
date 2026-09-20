import Foundation
@testable import Intent
import Testing

/// Every event type intentd can emit on a channel a store consumes must be a
/// deliberate decision in that store's classification tables. The catalog is
/// the vendored intentd golden `IntentTests/Fixtures/event_types.json`
/// (`crates/intent-core/tests/goldens/event_types.json` in intent-hq/intentd);
/// re-vendor it when the daemon adds a type, then classify the new type.
private struct EventCatalogDiscriminator: Decodable {
    let path: String
    let kind: String
    let values: [String]
    let absent: String?
}

struct EventCatalogCoverageTests {
    // MARK: - Golden

    private struct Golden: Decodable {
        let version: Int
        let types: [String]
        let discriminators: [String: EventCatalogDiscriminator]
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
        let golden = Self.golden
        #expect(golden.version == 1)
        #expect(!golden.types.isEmpty)
        #expect(golden.types == golden.types.sorted(), "golden types must be sorted")
        #expect(Set(golden.types).count == golden.types.count, "golden types must be unique")
        for (type, discriminator) in golden.discriminators {
            #expect(golden.types.contains(type), "discriminator for unknown type \(type)")
            #expect(discriminator.kind == "value" || discriminator.kind == "keys", "\(type): unknown discriminator kind \(discriminator.kind)")
            #expect(!discriminator.values.isEmpty, "\(type): discriminator has no values")
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
        // swiftlint:disable:next discouraged_optional_collection
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
        absent: .ignore
    )

    /// `workspace:updated`: only a `lastActivity`-only delta is patched in
    /// place; every other key, and a missing `changes`, refetches.
    private static let workspaceUpdatedExpectation = DiscriminatorExpectation(
        values: [
            "lastActivity": .patchInPlace,
            "activePullRequest": .refetch,
            "archived": .refetch,
            "archivedAt": .refetch,
            "attention": .refetch,
            "autoCommitEnabled": .refetch,
            "autoUnarchive": .refetch,
            "baseCommitSha": .refetch,
            "baseRef": .refetch,
            "branch": .refetch,
            "browserClientId": .refetch,
            "defaultModel": .refetch,
            "isRemote": .refetch,
            "mcpServerToggled": .refetch,
            "members": .refetch,
            "path": .refetch,
            "prNumber": .refetch,
            "prStatus": .refetch,
            "prUrl": .refetch,
            "pullRequests": .refetch,
            "removedPrincipalId": .refetch,
            "repositoryName": .refetch,
            "repositoryOwner": .refetch,
            "repositoryPath": .refetch,
            "scope": .refetch,
            "setupScript": .refetch,
            "skipIsolation": .refetch,
            "status": .refetch,
            "statusImageAssetId": .refetch,
            "statusMessage": .refetch,
            "tags": .refetch,
            "title": .refetch,
            "worktreePath": .refetch
        ],
        absent: .refetch
    )

    private static let stores: [StoreTables] = [
        StoreTables(
            name: "AgentStore",
            channels: AgentStore.handledChannels,
            refetch: AgentStore.refetchEventTypes,
            patchInPlace: [],
            ignore: AgentStore.ignoredEventTypes,
            discriminatorValues: [:],
            discriminatorExpectations: [:],
            classify: AgentStore.classify
        ),
        StoreTables(
            name: "NoteStore",
            channels: NoteStore.handledChannels,
            refetch: NoteStore.refetchEventTypes,
            patchInPlace: [],
            ignore: NoteStore.ignoredEventTypes,
            discriminatorValues: [:],
            discriminatorExpectations: [:],
            classify: NoteStore.classify
        ),
        StoreTables(
            name: "TaskStore",
            channels: TaskStore.handledChannels,
            refetch: TaskStore.refetchEventTypes,
            patchInPlace: [],
            ignore: TaskStore.ignoredEventTypes,
            discriminatorValues: [
                "task:ready-tasks-changed": Set(TaskStore.readyTasksChangedReasonClassification.keys)
            ],
            discriminatorExpectations: ["task:ready-tasks-changed": readyTasksChangedExpectation],
            classify: TaskStore.classify
        ),
        StoreTables(
            name: "WorkspaceStore",
            channels: WorkspaceStore.handledChannels,
            refetch: WorkspaceStore.refetchEventTypes,
            patchInPlace: WorkspaceStore.patchInPlaceEventTypes,
            ignore: WorkspaceStore.ignoredEventTypes,
            discriminatorValues: [
                "workspace:updated": Set(WorkspaceStore.workspaceUpdatedChangeKeyClassification.keys)
            ],
            discriminatorExpectations: ["workspace:updated": workspaceUpdatedExpectation],
            classify: WorkspaceStore.classify
        )
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
}

extension EventCatalogCoverageTests {
    @Test func everyDiscriminatorValueIsClassified() {
        for store in Self.stores {
            for (type, discriminator) in Self.golden.discriminators
                where store.channels.contains(where: { type.hasPrefix($0) }) {
                Self.verify(type: type, discriminator: discriminator, for: store)
            }
            for type in store.discriminatorValues.keys {
                #expect(
                    Self.golden.discriminators[type] != nil,
                    "\(store.name) has a discriminator table for \(type), which the catalog does not discriminate"
                )
            }
            for type in store.discriminatorExpectations.keys {
                #expect(
                    store.discriminatorValues[type] != nil,
                    "\(store.name) has expected classifications for \(type) but no discriminator table"
                )
            }
        }
    }

    private static func verify(type: String, discriminator: EventCatalogDiscriminator, for store: StoreTables) {
        guard let named = store.discriminatorValues[type] else {
            Issue.record("\(store.name) has no discriminator table for \(type)")
            return
        }
        guard let expectation = store.discriminatorExpectations[type] else {
            Issue.record("\(store.name) has no expected classifications for \(type) in this test")
            return
        }
        let goldenValues = Set(discriminator.values)
        let expectedValues = Set(expectation.values.keys)
        #expect(
            named.subtracting(goldenValues).isEmpty,
            "\(store.name) names \(type) discriminator values not in the catalog: \(named.subtracting(goldenValues))"
        )
        #expect(
            expectedValues == goldenValues,
            "\(store.name) expectations for \(type) must list exactly the catalog's discriminator values; extra: \(expectedValues.subtracting(goldenValues)), missing: \(goldenValues.subtracting(expectedValues))"
        )
        let coverage = (named: named, expectation: expectation)
        for value in discriminator.values {
            verify(value: value, type: type, discriminator: discriminator, coverage: coverage, for: store)
        }
        let absentActual = store.classify(type, [:])
        #expect(absentActual != nil, "\(store.name) does not classify \(type) when \(discriminator.path) is absent")
        #expect(
            absentActual == expectation.absent,
            "\(store.name) classifies \(type) with \(discriminator.path) absent as \(String(describing: absentActual)), expected \(expectation.absent)"
        )
        verifyKeyDominance(type: type, discriminator: discriminator, expectation: expectation, for: store)
    }

    private static func verify(
        value: String,
        type: String,
        discriminator: EventCatalogDiscriminator,
        coverage: (named: Set<String>, expectation: DiscriminatorExpectation),
        for store: StoreTables
    ) {
        #expect(coverage.named.contains(value), "\(store.name) does not classify \(type) with \(discriminator.path) = \(value)")
        let payload: [String: Any]
        switch discriminator.kind {
        case "value": payload = Self.data(at: discriminator.path, leaf: value)
        case "keys": payload = Self.data(at: discriminator.path, leaf: [value: "x"])
        default: Issue.record("\(type): unknown discriminator kind \(discriminator.kind)"); return
        }
        let expected = coverage.expectation.values[value]
        let actual = store.classify(type, payload)
        #expect(actual != nil, "\(store.name) does not classify \(type) with \(discriminator.path) = \(value)")
        #expect(
            actual == expected,
            "\(store.name) classifies \(type) with \(discriminator.path) = \(value) as \(String(describing: actual)), expected \(String(describing: expected))"
        )
    }

    private static func verifyKeyDominance(
        type: String,
        discriminator: EventCatalogDiscriminator,
        expectation: DiscriminatorExpectation,
        for store: StoreTables
    ) {
        guard discriminator.kind == "keys" else { return }
        let patched = expectation.values.filter { $0.value == .patchInPlace }.keys
        let refetched = expectation.values.filter { $0.value == .refetch }.keys
        for patchKey in patched {
            for refetchKey in refetched {
                let payload = Self.data(at: discriminator.path, leaf: [patchKey: "x", refetchKey: "x"])
                let actual = store.classify(type, payload)
                #expect(
                    actual == .refetch,
                    "\(store.name) classifies \(type) with \(discriminator.path) keys [\(patchKey), \(refetchKey)] as \(String(describing: actual)); a refetch key must dominate"
                )
            }
        }
    }

    /// A store's tables are inert unless `ConnectionManager` subscribes to
    /// the channel globally.
    @Test func globalSubscriptionCoversEveryHandledChannel() {
        for store in Self.stores {
            for channel in store.channels {
                #expect(
                    ConnectionManager.globalEventTypes.contains(channel + "*"),
                    "\(store.name) handles \(channel) but ConnectionManager.globalEventTypes = \(ConnectionManager.globalEventTypes)"
                )
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
                #expect(
                    store.classify(type, nil) != nil,
                    "\(store.name) does not classify \(type)"
                )
            }
        }
    }

    /// A table entry the catalog does not contain is a typo or a type the
    /// daemon no longer emits.
    @Test func everyTableEntryIsInCatalog() {
        let catalog = Set(Self.golden.types)
        for store in Self.stores {
            for type in store.refetch.union(store.patchInPlace).union(store.ignore) {
                #expect(
                    catalog.contains(type),
                    "\(store.name) classifies \(type), which is not in the catalog"
                )
                #expect(
                    store.channels.contains { type.hasPrefix($0) },
                    "\(store.name) classifies \(type) outside its channels \(store.channels)"
                )
            }
        }
    }

    @Test func classificationSetsAreDisjoint() {
        for store in Self.stores {
            #expect(
                store.refetch.isDisjoint(with: store.patchInPlace),
                "\(store.name): refetch ∩ patchInPlace = \(store.refetch.intersection(store.patchInPlace))"
            )
            #expect(
                store.refetch.isDisjoint(with: store.ignore),
                "\(store.name): refetch ∩ ignore = \(store.refetch.intersection(store.ignore))"
            )
            #expect(
                store.patchInPlace.isDisjoint(with: store.ignore),
                "\(store.name): patchInPlace ∩ ignore = \(store.patchInPlace.intersection(store.ignore))"
            )
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
