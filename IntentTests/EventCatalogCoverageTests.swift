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
        let classify: (String, [String: Any]?) -> EventClassification?
    }

    private static let stores: [StoreTables] = [
        StoreTables(
            name: "AgentStore", channels: AgentStore.handledChannels,
            refetch: AgentStore.refetchEventTypes, patchInPlace: [],
            ignore: AgentStore.ignoredEventTypes, discriminatorValues: [:],
            classify: AgentStore.classify),
        StoreTables(
            name: "NoteStore", channels: NoteStore.handledChannels,
            refetch: NoteStore.refetchEventTypes, patchInPlace: [],
            ignore: NoteStore.ignoredEventTypes, discriminatorValues: [:],
            classify: NoteStore.classify),
        StoreTables(
            name: "TaskStore", channels: TaskStore.handledChannels,
            refetch: TaskStore.refetchEventTypes, patchInPlace: [],
            ignore: TaskStore.ignoredEventTypes,
            discriminatorValues: [
                "task:ready-tasks-changed": Set(TaskStore.readyTasksChangedReasonClassification.keys),
            ],
            classify: TaskStore.classify),
        StoreTables(
            name: "WorkspaceStore", channels: WorkspaceStore.handledChannels,
            refetch: WorkspaceStore.refetchEventTypes,
            patchInPlace: WorkspaceStore.patchInPlaceEventTypes,
            ignore: WorkspaceStore.ignoredEventTypes,
            discriminatorValues: [
                "workspace:updated": Set(WorkspaceStore.workspaceUpdatedChangeKeyClassification.keys),
            ],
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
    /// classify; the `absent` shape must classify too.
    @Test func everyDiscriminatorValueIsClassified() {
        for store in Self.stores {
            for (type, d) in Self.golden.discriminators
            where store.channels.contains(where: { type.hasPrefix($0) }) {
                guard let named = store.discriminatorValues[type] else {
                    Issue.record("\(store.name) has no discriminator table for \(type)")
                    continue
                }
                let goldenValues = Set(d.values)
                #expect(named.subtracting(goldenValues).isEmpty,
                        "\(store.name) names \(type) discriminator values not in the catalog: \(named.subtracting(goldenValues))")
                for value in d.values {
                    #expect(named.contains(value),
                            "\(store.name) does not classify \(type) with \(d.path) = \(value)")
                    let payload: [String: Any]
                    switch d.kind {
                    case "value": payload = Self.data(at: d.path, leaf: value)
                    case "keys": payload = Self.data(at: d.path, leaf: [value: "x"])
                    default: Issue.record("\(type): unknown discriminator kind \(d.kind)"); continue
                    }
                    #expect(store.classify(type, payload) != nil,
                            "\(store.name) does not classify \(type) with \(d.path) = \(value)")
                }
                if d.absent != nil {
                    #expect(store.classify(type, [:]) != nil,
                            "\(store.name) does not classify \(type) when \(d.path) is absent")
                }
            }
            for type in store.discriminatorValues.keys {
                #expect(Self.golden.discriminators[type] != nil,
                        "\(store.name) has a discriminator table for \(type), which the catalog does not discriminate")
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
