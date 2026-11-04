#if DEBUG
import Foundation
import UIKit

extension DemoFixtures {
    /// Opt-in so existing demo transcripts and screenshots stay unchanged.
    static var usesInlinePDF: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return DemoMode.demoDataRequested(by: arguments) && arguments.contains("--demo-inline-pdfs")
    }

    private static let inlinePDFPath = "docs/Demo brief.pdf"

    static var inlinePDFMessages: [[String: Any]] {
        let url = "intent://local/file/docs/Demo%20brief.pdf"
        let text = [
            "Here is the project brief.",
            "PDF preview:  \n![Project brief](\(url))",
            "[Open the PDF brief](\(url))",
            "[Open the missing PDF](intent://local/file/docs/Missing%20brief.pdf)",
            "The brief is ready to review and share."
        ].joined(separator: "\n\n")
        return [
            [
                "id": "demo-pdf-assistant", "role": "assistant", "timestamp": transcriptIso(minutesAgo: 1),
                "contentBlocks": [["type": "text", "text": text]]
            ]
        ]
    }

    static func inlinePDFResponse(for method: String, params: [String: Any]) -> Any? {
        guard usesInlinePDF, method == "file.readChunk",
              params["workspaceId"] as? String == "demo-ws-dashboard",
              params["path"] as? String == inlinePDFPath else { return nil }
        let offset = params["offset"] as? Int ?? 0
        let length = params["length"] as? Int ?? 0
        guard offset >= 0, offset <= inlinePDFBytes.count, length > 0 else { return [:] }
        let chunk = inlinePDFBytes.dropFirst(offset).prefix(length)
        return [
            "content": chunk.base64EncodedString(), "bytesRead": chunk.count,
            "size": inlinePDFBytes.count
        ]
    }

    /// Generated once in memory; no network, external tool, or bundle resource needed.
    private static let inlinePDFBytes: Data = {
        let pageWidth: CGFloat = 300
        let pageHeight: CGFloat = 400
        let inset: CGFloat = 24
        let bodyY: CGFloat = 80
        let bodyFontSize: CGFloat = 16
        let bounds = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        let pages = [
            ("Intent project brief", "A small PDF shared in chat.\n\nPreview, open, and share it without leaving the conversation."),
            ("Review checklist", "1. Read the project brief.\n\n2. Review the second page.\n\n3. Share the PDF with your team.")
        ]
        return UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
            for (title, body) in pages {
                context.beginPage()
                UIColor.white.setFill()
                context.fill(bounds)
                NSAttributedString(string: title, attributes: [
                    .font: UIFont.boldSystemFont(ofSize: inset), .foregroundColor: UIColor.black
                ]).draw(at: CGPoint(x: inset, y: inset))
                NSAttributedString(string: body, attributes: [
                    .font: UIFont.systemFont(ofSize: bodyFontSize), .foregroundColor: UIColor.darkGray
                ]).draw(in: CGRect(x: inset, y: bodyY, width: pageWidth - inset * 2, height: pageHeight - bodyY - inset))
            }
        }
    }()
}
#endif
