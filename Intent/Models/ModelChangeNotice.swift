import Foundation

struct ModelChangeNotice: Equatable {
    let from: String?
    let destination: String?
    let fromProvider: String?
    let toProvider: String?

    init(from: String?, to destination: String?, fromProvider: String?, toProvider: String?) {
        self.from = from
        self.destination = destination
        self.fromProvider = fromProvider
        self.toProvider = toProvider
    }

    static let fallbackLabel = "Model changed"

    func label(fallbackText: String) -> String {
        guard let fromLabel = Self.describeSide(providerId: fromProvider, model: from),
              let toLabel = Self.describeSide(providerId: toProvider, model: destination) else {
            let trimmed = fallbackText.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? Self.fallbackLabel : trimmed
        }
        return "Switched from \(fromLabel) to \(toLabel)"
    }

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
    var modelChangeNotice: ModelChangeNotice? {
        guard metadata["type"]?.value as? String == "model_changed" else {
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
