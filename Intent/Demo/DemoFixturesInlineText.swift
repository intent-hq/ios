#if DEBUG
import Foundation
import UIKit

extension DemoFixtures {
    /// Opt-in so existing demo transcripts and screenshots stay unchanged.
    static var usesInlineText: Bool {
        let arguments = LaunchOptions.current.arguments
        return DemoMode.demoDataRequested(by: arguments) && arguments.contains("--demo-inline-text")
    }

    private static let inlineTextPath = "docs/Demo notes.txt"
    /// Linked as a relative path, the way agents often write report links.
    private static let inlineHTMLPath = "reports/Demo report.html"
    /// Referenced from the report by relative URLs, as generated reports do.
    private static let inlineReportStylesheetPath = "reports/assets/report.css"
    private static let inlineReportChartPath = "reports/images/usage-chart.png"
    private static let inlineReportFontPath = "reports/assets/fonts/Inter-ExtraBold.ttf"
    /// Where the demo workspace sits on the Mac, for links written as absolute paths.
    /// The daemon accepts an absolute path inside the workspace, so the report's files serve from both.
    private static let inlineWorkspaceFolder = "/Users/demo/dashboard/"

    static var inlineTextMessages: [[String: Any]] {
        let text = [
            "Here are the project notes.",
            "[Open the text notes](intent://local/file/docs/Demo%20notes.txt)",
            "[Open the missing text file](intent://local/file/docs/Missing%20notes.txt)",
            "[Open the HTML report](reports/Demo%20report.html)",
            "[Open the HTML report by absolute path](/Users/demo/dashboard/reports/Demo%20report.html)",
            // Links the app can't open: each tap shows a message instead of doing nothing.
            "[Open the workspace settings](intent://local/settings)",
            "[Open the signed-in preview](http://user@localhost:3000)",
            "The notes are ready to review and share."
        ].joined(separator: "\n\n")
        return [
            [
                "id": "demo-text-assistant", "role": "assistant", "timestamp": transcriptIso(minutesAgo: 1),
                "contentBlocks": [["type": "text", "text": text]]
            ]
        ]
    }

    static func inlineTextResponse(for method: String, params: [String: Any]) -> Any? {
        guard usesInlineText, method == "file.readChunk",
              params["workspaceId"] as? String == "demo-ws-dashboard",
              let bytes = inlineFiles[params["path"] as? String ?? ""] else { return nil }
        let offset = params["offset"] as? Int ?? 0
        let length = params["length"] as? Int ?? 0
        guard offset >= 0, offset <= bytes.count, length > 0 else { return [:] }
        let chunk = bytes.dropFirst(offset).prefix(length)
        return [
            "content": chunk.base64EncodedString(), "bytesRead": chunk.count,
            "size": bytes.count
        ]
    }

    private static var inlineFiles: [String: Data] {
        let files = [
            inlineTextPath: inlineTextBytes, inlineHTMLPath: inlineHTMLBytes,
            inlineReportStylesheetPath: inlineReportStylesheetBytes, inlineReportChartPath: inlineReportChartBytes,
            inlineReportFontPath: inlineReportFontBytes
        ]
        let absolute = files.map { (inlineWorkspaceFolder + $0.key, $0.value) }
        return files.merging(absolute) { relative, _ in relative }
    }

    /// The app's own bundled Inter (SIL OFL 1.1, Inter-LICENSE.txt), served under a report-only
    /// family name: the web content process cannot see app-registered fonts, so it renders only via @font-face.
    private static let inlineReportFontBytes: Data = {
        guard let url = Bundle.main.url(forResource: "Inter-ExtraBold", withExtension: "ttf") else { return Data() }
        return (try? Data(contentsOf: url)) ?? Data()
    }()

    /// The inline rule hides the note; only the external stylesheet shows it,
    /// so the note's presence proves the relative stylesheet loaded.
    private static let inlineHTMLBytes = Data("""
    <!doctype html>
    <html><head><meta charset="utf-8"><title>Demo report</title>
    <style>.stylesheet-note { display: none; }</style>
    <link rel="stylesheet" href="assets/report.css">
    </head>
    <body>
    <h1>Usage analytics report</h1>
    <p>Daily active users rose 12% this week.</p>
    <img class="chart" src="images/usage-chart.png" alt="Daily active users chart">
    <p class="stylesheet-note">Styled by assets/report.css</p>
    </body></html>
    """.utf8)

    private static let inlineReportStylesheetBytes = Data("""
    @font-face { font-family: "Report Display"; src: url("fonts/Inter-ExtraBold.ttf") format("truetype"); font-weight: 800; }
    :root { color-scheme: light dark; --accent: #2f6fde; --surface: #f2f5fb; --text: #1b1f27; }
    @media (prefers-color-scheme: dark) {
      :root { --accent: #7aa7ff; --surface: #1d2230; --text: #e8ecf4; }
    }
    body { font: -apple-system-body; margin: 16px; color: var(--text); background: var(--surface); }
    h1 { color: var(--accent); font: 800 1.8em "Report Display", serif; }
    .chart { display: block; width: 100%; height: auto; border-radius: 12px; border: 2px solid var(--accent); }
    .stylesheet-note { display: block; color: var(--accent); font-weight: 600; }
    """.utf8)

    // Chart geometry and bar heights are fixture data, not tunable constants.
    // swiftlint:disable no_magic_numbers
    /// Generated once in memory; no network, external tool, or bundle resource needed.
    private static let inlineReportChartBytes: Data = {
        let size = CGSize(width: 600, height: 300)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let values: [CGFloat] = [0.42, 0.55, 0.48, 0.63, 0.71, 0.68, 0.82]
        let inset: CGFloat = 30
        let gap: CGFloat = 16
        return UIGraphicsImageRenderer(size: size, format: format).pngData { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let barWidth = (size.width - inset * 2 - gap * CGFloat(values.count - 1)) / CGFloat(values.count)
            let chartHeight = size.height - inset * 2
            UIColor.systemBlue.setFill()
            for (index, value) in values.enumerated() {
                let height = chartHeight * value
                let originX = inset + CGFloat(index) * (barWidth + gap)
                UIBezierPath(
                    roundedRect: CGRect(x: originX, y: size.height - inset - height, width: barWidth, height: height),
                    cornerRadius: 6
                ).fill()
            }
        }
    }()
    // swiftlint:enable no_magic_numbers

    private static let inlineTextBytes = Data("""
    Intent project notes

    A small UTF-8 text file shared in chat.

    Café review — ready to share.

    This deliberately long line wraps within the viewer so the entire note stays readable without horizontal scrolling, even on a narrow phone screen.

    Review checklist
    1. Read the notes.
    2. Share the original text file.
    3. Return to the conversation.
    """.utf8)
}
#endif
