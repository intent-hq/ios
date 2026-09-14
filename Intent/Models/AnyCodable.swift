import Foundation

/// A type-erased Codable wrapper for arbitrary JSON values.
struct AnyCodable: Codable, Equatable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = NSNull()
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([Self].self) {
            value = array.map { $0.value }
        } else if let dict = try? container.decode([String: Self].self) {
            value = dict.mapValues { $0.value }
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case is NSNull:
            try container.encodeNil()
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            try container.encode(array.map { Self($0) })
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { Self($0) })
        default:
            try container.encodeNil()
        }
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        // Simple equality based on JSON representation
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let lhsData = try? encoder.encode(lhs),
              let rhsData = try? encoder.encode(rhs) else { return false }
        return lhsData == rhsData
    }

    // MARK: - Convenience accessors

    var stringValue: String? { value as? String }
    var intValue: Int? { value as? Int }
    var doubleValue: Double? { value as? Double }
    var boolValue: Bool? { value as? Bool }
    var arrayValue: [Any]? { value as? [Any] }
    var dictValue: [String: Any]? { value as? [String: Any] }
    var isNull: Bool { value is NSNull }
}
