import Foundation

struct ActionProposal: Decodable {
    struct Preview: Decodable {
        let title: String
        let summary: String?
        let applyLabel: String?
        let bulkItems: [Item]
        let warnings: [String]
    }

    struct Item: Decodable, Identifiable {
        let id: String
        let title: String
        let summary: String?
        let selected: Bool
        let disabled: Bool
    }

    let kind: String
    let payload: [String: AnyCodable]
    let preview: Preview
    let applyToolCallId: String?

    var id: String { applyToolCallId ?? preview.title }
    var workspaceIDs: [String] { payload["ids"]?.value as? [String] ?? [] }
    var method: String? {
        guard kind == "bulk-op", !workspaceIDs.isEmpty else { return nil }
        switch payload["operation"]?.value as? String {
        case "workspace.bulkArchive": return "workspace.archive"
        case "workspace.bulkDelete": return "workspace.delete"
        default: return nil
        }
    }
    var items: [Item] {
        var seen: Set<String> = []
        return workspaceIDs.filter { seen.insert($0).inserted }.map { id in
            preview.bulkItems.first { $0.id == id }
                ?? Item(id: id, title: id, summary: nil, selected: true, disabled: false)
        }
    }
    var selectableIDs: Set<String> { Set(items.filter { $0.disabled != true }.map(\.id)) }
    var initialSelection: Set<String> { Set(items.filter { $0.selected != false && $0.disabled != true }.map(\.id)) }

    static func parse(_ block: ContentBlock) -> Self? {
        guard block.type == .resource,
              block.resource?.mimeType == "application/vnd.intent.proposal+json",
              let text = block.resource?.text else { return nil }
        return try? JSONDecoder().decode(Self.self, from: Data(text.utf8))
    }
}

extension ActionProposal.Item {
    private enum CodingKeys: String, CodingKey {
        case disabled, id, selected, summary, title
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        selected = try container.decodeIfPresent(Bool.self, forKey: .selected) ?? true
        disabled = try container.decodeIfPresent(Bool.self, forKey: .disabled) ?? false
    }
}

extension ActionProposal.Preview {
    private enum CodingKeys: String, CodingKey {
        case applyLabel, bulkItems, summary, title, warnings
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        applyLabel = try container.decodeIfPresent(String.self, forKey: .applyLabel)
        bulkItems = try container.decodeIfPresent([ActionProposal.Item].self, forKey: .bulkItems) ?? []
        warnings = try container.decodeIfPresent([String].self, forKey: .warnings) ?? []
    }
}
