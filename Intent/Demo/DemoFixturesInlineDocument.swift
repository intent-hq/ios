#if DEBUG
import Foundation

extension DemoFixtures {
    static var usesInlineDocument: Bool {
        let arguments = LaunchOptions.current.arguments
        return DemoMode.demoDataRequested(by: arguments) && arguments.contains("--demo-inline-documents")
    }

    private static let inlineSpreadsheetPath = "reports/Demo budget.xlsx"

    static var inlineDocumentMessages: [[String: Any]] {
        let text = [
            "Here is the budget.",
            "[Open the budget spreadsheet](intent://local/file/reports/Demo%20budget.xlsx)",
            "[Open the missing spreadsheet](intent://local/file/reports/Missing%20budget.xlsx)",
            "The spreadsheet is ready to review and share."
        ].joined(separator: "\n\n")
        return [
            [
                "id": "demo-document-assistant", "role": "assistant", "timestamp": transcriptIso(minutesAgo: 1),
                "contentBlocks": [["type": "text", "text": text]]
            ]
        ]
    }

    static func inlineDocumentResponse(for method: String, params: [String: Any]) -> Any? {
        guard usesInlineDocument, method == "file.readChunk",
              params["workspaceId"] as? String == "demo-ws-dashboard",
              params["path"] as? String == inlineSpreadsheetPath else { return nil }
        let offset = params["offset"] as? Int ?? 0
        let length = params["length"] as? Int ?? 0
        guard offset >= 0, offset <= inlineSpreadsheetBytes.count, length > 0 else { return [:] }
        let chunk = inlineSpreadsheetBytes.dropFirst(offset).prefix(length)
        return [
            "content": chunk.base64EncodedString(), "bytesRead": chunk.count,
            "size": inlineSpreadsheetBytes.count
        ]
    }

    private static let inlineSpreadsheetBytes = Data(
        base64Encoded: inlineSpreadsheetBase64,
        options: .ignoreUnknownCharacters
    ) ?? Data()
    private static let inlineSpreadsheetBase64 = """
    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
    dDEueG1sUEsFBgAAAAAFAAUARQEAADMFAAAAAA==
    """
}
#endif
