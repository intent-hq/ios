import Foundation

/// A daemon-persisted model-change transcript notice (PROTOCOL §5.5,
/// `agent.setModel`). When a turn starts under a different model/provider
/// identity than the last committed turn, intentd persists an informational
/// `role: "system"` row with metadata
/// `{ type: "model_changed", from: string | null, to: string | null,
///    fromProvider: string, toProvider: string }` —
/// `from`/`to` are spawn-resolved raw model ids (no provider prefix) and
/// nil means "provider default model". The row is transcript-only (never
/// replayed to providers) and renders as a centered informational chip, not
/// the amber warning banner (FE parity: model-change-notice.ts).
struct ModelChangeNotice: Equatable {
    /// Spawn-resolved model id; nil = provider default model.
    let from: String?
    let to: String?
    let fromProvider: String?
    let toProvider: String?

    /// Last-resort label when the metadata fields and the row text are both
    /// empty (FE parity: chat_modelChangeNotice_fallback_label).
    static let fallbackLabel = "Model changed"

    /// Display label — "Switched from <side> to <side>" — or `fallbackText`
    /// (the row's text content) when either side of the switch cannot be
    /// described from the metadata (FE parity: formatModelChangeLabel).
    /// The side format is intentionally simplified vs the FE strings —
    /// "<modelId> (<provider name>)" instead of the FE's
    /// "<pretty name> (<providerId> / <modelId>)" — because iOS has no model
    /// catalog to resolve pretty names from.
    func label(fallbackText: String) -> String {
        guard let fromLabel = Self.describeSide(providerId: fromProvider, model: from),
              let toLabel = Self.describeSide(providerId: toProvider, model: to) else {
            let trimmed = fallbackText.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? Self.fallbackLabel : trimmed
        }
        return "Switched from \(fromLabel) to \(toLabel)"
    }

    /// One side of the switch: "<modelId> (<provider name>)" when both are
    /// known, "<provider name> default model" for a nil model id, the bare
    /// model id without a provider, or nil when neither is known.
    private static func describeSide(providerId: String?, model: String?) -> String? {
        if let providerId, !providerId.isEmpty {
            let providerName = ProviderInfo.displayName(for: providerId)
            if let model, !model.isEmpty {
                return "\(model) (\(providerName))"
            }
            return "\(providerName) default model"
        }
        if let model, !model.isEmpty { return model }
        return nil
    }
}

extension ConversationMessage {
    /// Returns the model-change info when this message is a daemon-persisted
    /// model-change notice row, or nil for every other message. Discriminates
    /// purely on `metadata.type == "model_changed"` so the client stays
    /// tolerant of the exact role the daemon persists (non-user/non-assistant
    /// by contract); absent or malformed metadata returns nil, so those rows
    /// keep the generic system banner (FE parity: getModelChangeNotice).
    var modelChangeNotice: ModelChangeNotice? {
        guard let metadata,
              metadata["type"]?.value as? String == "model_changed" else {
            return nil
        }
        func asString(_ key: String) -> String? {
            guard let value = metadata[key]?.value as? String, !value.isEmpty else { return nil }
            return value
        }
        return ModelChangeNotice(
            from: asString("from"),
            to: asString("to"),
            fromProvider: asString("fromProvider"),
            toProvider: asString("toProvider")
        )
    }
}
