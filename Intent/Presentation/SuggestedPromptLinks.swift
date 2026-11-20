import Foundation
import SwiftUI

enum SuggestedPromptLinks {
    private enum Part {
        case link(label: [Unicode.Scalar], url: [Unicode.Scalar])
        case text([Unicode.Scalar])
    }

    private struct Destination {
        let url: [Unicode.Scalar]
        let end: Int
    }

    private struct Construct {
        let end: Int
        let label: [Unicode.Scalar]
        let destination: Destination?
    }

    static func visibleText(_ prompt: String) -> String {
        var scalars = String.UnicodeScalarView()
        for part in parts(Array(prompt.unicodeScalars)) {
            switch part {
            case let .text(content): scalars.append(contentsOf: content)
            case let .link(label, _): scalars.append(contentsOf: label)
            }
        }
        return String(scalars)
    }

    static func textAfterLabel(_ line: String) -> String? {
        let scalars = Array(line.unicodeScalars)
        var offset = 0
        for part in parts(scalars) {
            switch part {
            case let .text(content):
                if let pipe = content.firstIndex(of: "|") {
                    return String(String.UnicodeScalarView(scalars[(offset + pipe + 1)...]))
                }
                offset += content.count
            case let .link(label, url):
                offset += label.count + url.count + linkSyntaxLength
            }
        }
        return nil
    }

    private static let linkSyntaxLength = 4
    private static let linkSchemes = ["http://", "https://", "intent://"]

    private static func parts(_ prompt: [Unicode.Scalar]) -> [Part] {
        var result: [Part] = []
        var textStart = 0
        var index = 0
        while index < prompt.count {
            guard prompt[index] == "[" else {
                index += 1
                continue
            }
            let construct = bracketConstruct(prompt, open: index)
            let isImage = index > 0 && prompt[index - 1] == "!"
            if let url = construct.destination?.url, !isImage, isLinkLabel(construct.label), hasLinkScheme(url) {
                if index > textStart { result.append(.text(Array(prompt[textStart..<index]))) }
                result.append(.link(label: construct.label, url: url))
                textStart = construct.end
            }
            index = max(construct.end, index + 1)
        }
        if textStart < prompt.count { result.append(.text(Array(prompt[textStart...]))) }
        return result
    }

    private static func bracketConstruct(_ prompt: [Unicode.Scalar], open: Int) -> Construct {
        var depth = 0
        var close = open
        while close < prompt.count {
            let scalar = prompt[close]
            if scalar == "\n" { return Construct(end: close, label: [], destination: nil) }
            if scalar == "[" {
                depth += 1
            } else if scalar == "]" {
                depth -= 1
                if depth == 0 { break }
            }
            close += 1
        }
        guard close < prompt.count else { return Construct(end: prompt.count, label: [], destination: nil) }
        let label = Array(prompt[(open + 1)..<close])
        guard close + 1 < prompt.count, prompt[close + 1] == "(",
              let destination = destination(prompt, start: close + 2) else {
            return Construct(end: close + 1, label: label, destination: nil)
        }
        return Construct(end: destination.end, label: label, destination: destination)
    }

    private static func destination(_ prompt: [Unicode.Scalar], start: Int) -> Destination? {
        var depth = 0
        var index = start
        while index < prompt.count {
            let scalar = prompt[index]
            if scalar == "<" || scalar == ">" || scalar.properties.isWhitespace { return nil }
            if scalar == "(" {
                if depth > 0 { return nil }
                depth += 1
            } else if scalar == ")" {
                if depth == 0 { break }
                depth -= 1
            }
            index += 1
        }
        guard index < prompt.count, index > start else { return nil }
        return Destination(url: Array(prompt[start..<index]), end: index + 1)
    }

    private static func isLinkLabel(_ label: [Unicode.Scalar]) -> Bool {
        let text = String(String.UnicodeScalarView(label))
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !label.contains { $0 == "[" || $0 == "]" || $0 == "\n" }
    }

    private static func hasLinkScheme(_ url: [Unicode.Scalar]) -> Bool {
        let lowered = String(String.UnicodeScalarView(url.prefix(linkSchemes.map(\.count).max() ?? 0))).lowercased()
        return linkSchemes.contains { lowered.hasPrefix($0) }
    }
}

extension SuggestedPromptLinks {
    static func displayText(_ prompt: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        var text = (try? AttributedString(markdown: prompt, options: options)) ?? AttributedString(prompt)
        for run in text.runs where run.link != nil {
            text[run.range].link = nil
            text[run.range].underlineStyle = .single
        }
        return text
    }
}
