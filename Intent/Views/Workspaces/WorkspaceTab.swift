enum WorkspaceTab: Hashable {
    case agents
    case changes
    case context
    case unsupportedPersistedValue(Int)

    init(persistedValue: Int) {
        switch persistedValue {
        case 0:
            self = .agents
        case 1:
            self = .context
        case 2:
            self = .changes
        default:
            self = .unsupportedPersistedValue(persistedValue)
        }
    }

    var persistedValue: Int {
        switch self {
        case .agents:
            0
        case .context:
            1
        case .changes:
            2
        case let .unsupportedPersistedValue(value):
            value
        }
    }

    static func restored(persistedValue: Int?, fallback: Self) -> Self {
        guard let persistedValue else { return fallback }
        return Self(persistedValue: persistedValue)
    }
}
