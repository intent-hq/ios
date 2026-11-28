import Foundation

enum BrowserCompleteMarker {
    private static let leadingMarker = #/^\s*::browser-complete\{(?:"(?:[^"\\\n]|\\.)*"|[^}"\n])*\}[ \t]*/#

    static func strip(from text: String) -> String {
        guard text.contains("::browser-complete{") else { return text }
        return text.replacing(leadingMarker, with: "", maxReplacements: 1)
    }
}
