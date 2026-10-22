import Foundation

struct SkillInfo: Identifiable, Hashable, Sendable {
    var id: String { location }
    let name: String
    let description: String
    let location: String
    let scope: String
    let resourceDirectory: String?

    init(name: String, description: String, location: String, scope: String, resourceDirectory: String? = nil) {
        self.name = name
        self.description = description
        self.location = location
        self.scope = scope
        self.resourceDirectory = resourceDirectory
    }

    init?(wire: [String: Any]) {
        guard let name = wire["name"] as? String,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let description = wire["description"] as? String,
              let location = wire["location"] as? String,
              !location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let scope = wire["scope"] as? String,
              !scope.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        self.init(
            name: name,
            description: description,
            location: location,
            scope: scope,
            resourceDirectory: wire["resourceDirectory"] as? String
        )
    }
}
