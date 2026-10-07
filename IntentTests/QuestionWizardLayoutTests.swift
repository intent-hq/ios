@testable import Intent
import SwiftUI
import Testing
import UIKit

@MainActor
@Suite(.serialized, .enabled("The synthetic host must publish accessible controls") {
    await SyntheticBadgeHost.publishesAccessibilityTree()
})
struct QuestionWizardLayoutTests {
    @Test func composerPagingAutoAdvancesAndRestoresSelection() async throws {
        let questions = [
            Question(attachmentId: "first", header: "First", question: "Choose a direction", options: [
                QuestionOption(label: "Forward"), QuestionOption(label: "Wait")
            ]),
            Question(attachmentId: "last", header: "Last", question: "Choose a check", options: [
                QuestionOption(label: "Build"), QuestionOption(label: "Review")
            ])
        ]
        let wizard = QuestionWizardView(questions: questions, collapsed: .constant(false)) { _ in }
        try await SyntheticBadgeHost.render(wizard, width: 390, height: 700, safeAreaRegions: []) { host, _ in
            #expect(button("Back", in: host) == nil)
            #expect(button("Build", in: host) == nil, "Offscreen pages must not be exposed to VoiceOver")
            let forward = try #require(button("Forward", in: host))
            #expect(forward.accessibilityActivate())
            let build = try waitForButton("Build", in: host)
            #expect(host.convert(host.bounds, to: nil).contains(build.accessibilityFrame))
            waitForRemoval("Forward", in: host)
            #expect(button("Forward", in: host) == nil)
            let back = try #require(button("Back", in: host))
            #expect(back.accessibilityActivate())
            let restored = try waitForButton("Forward", in: host)
            #expect(restored.accessibilityValue == "Selected")
            waitForRemoval("Build", in: host)
            #expect(button("Back", in: host) == nil)
            #expect(button("Build", in: host) == nil)
        }
    }

    private func button(_ label: String, in host: UIView) -> NSObject? {
        SyntheticBadgeHost.accessibilityElements(in: host).first { element in
            element.accessibilityLabel == label && element.accessibilityTraits.contains(.button)
        }
    }

    private func waitForButton(_ label: String, in host: UIView) throws -> NSObject {
        let deadline = Date(timeIntervalSinceNow: 2)
        while Date() < deadline {
            if let control = button(label, in: host), host.convert(host.bounds, to: nil).contains(control.accessibilityFrame) {
                return control
            }
            _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
            host.layoutIfNeeded()
        }
        return try #require(button(label, in: host))
    }

    private func waitForRemoval(_ label: String, in host: UIView) {
        let deadline = Date(timeIntervalSinceNow: 2)
        while button(label, in: host) != nil, Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
            host.layoutIfNeeded()
        }
    }

    @Test(arguments: [CGFloat(320), CGFloat(390), CGFloat(600)])
    func cardsStayStackedAndScrollVerticallyWhenHeightIsLimited(width: CGFloat) async throws {
        let tall = try await render(width: width, height: 1000)
        #expect(tall.options.count == 4)
        #expect(!tall.scrollsHorizontally)
        #expect(!tall.scrollsVertically)
        for (previous, next) in zip(tall.options, tall.options.dropFirst()) {
            #expect(previous.maxY < next.minY)
            #expect(abs(previous.minX - next.minX) < 1)
        }
        #expect(tall.options.allSatisfy { tall.hostFrame.contains($0) && $0.height >= 44 })
        #expect(tall.hostFrame.contains(tall.sendFrame))
        #expect(tall.sendFrame.height >= 44)

        let compact = try await render(width: width, height: 400)
        #expect(!compact.scrollsHorizontally)
        #expect(compact.scrollsVertically)
        #expect(compact.options.count == 4)
        for (previous, next) in zip(compact.options, compact.options.dropFirst()) {
            #expect(previous.maxY < next.minY)
            #expect(abs(previous.minX - next.minX) < 1)
        }
        // Accessibility frame subtraction can report 43.99999999999997 for a 44pt target.
        #expect(compact.sendFrame.height >= 44 - 0.001, "Rendered action frame: \(compact.sendFrame)")
    }

    @Test func customAnswerCaretUsesTheDesignedTextEdge() async throws {
        let empty = try await renderAnswerText("")
        let typed = try await renderAnswerText("Message")
        // The design puts the text origin 20pt inside the field. Check UIKit's
        // real caret, not a duplicate of the padding formula or an ink threshold
        // whose result changes with the placeholder's opacity and antialiasing.
        #expect(abs(empty - 20) <= 1, "Empty caret x: \(empty)")
        #expect(abs(typed - 20) <= 1, "Typed text origin x: \(typed)")
    }

    private func renderAnswerText(_ text: String) async throws -> CGFloat {
        let view = AnswerTextHost(text: text)
        .environment(\.colorScheme, .light)
        .environment(\.dynamicTypeSize, .large)
        return try await SyntheticBadgeHost.render(view, width: 320, height: 100, safeAreaRegions: []) { hostView, _ in
            hostView.layoutIfNeeded()
            let (editor, input) = try #require(textInput(in: hostView))
            // No first responder is needed to measure the insertion rect.
            let caret = editor.convert(input.caretRect(for: input.beginningOfDocument), to: hostView)
            return caret.minX
        }
    }

    private func textInput(in view: UIView) -> (UIView, any UITextInput)? {
        if let input = view as? any UITextInput { return (view, input) }
        for child in view.subviews {
            if let result = textInput(in: child) { return result }
        }
        return nil
    }

    private struct AnswerTextHost: View {
        let text: String
        @FocusState private var focused: Bool

        var body: some View {
            WorkspaceQuestionFreeText(
                text: .constant(text),
                focused: $focused,
                isLast: true,
                onSubmit: {},
                onTextChange: {}
            )
        }
    }

    @Test func accessibilityTextUsesVerticalScrollingAndKeepsSelectionSemantics() async throws {
        let rendered = try await render(width: 320, height: 400, typeSize: .accessibility3)
        #expect(rendered.scrollsVertically)
        #expect(!rendered.scrollsHorizontally)
        #expect(rendered.firstLabel == "Answer 1")
        #expect(rendered.firstValue == "Selected")
        #expect(rendered.firstTraits.contains(.selected))
        #expect(rendered.firstTraits.contains(.button))
        #expect(rendered.options.allSatisfy { $0.width <= rendered.hostFrame.width && $0.height >= 44 })
    }

    private struct Rendered {
        let hostFrame: CGRect
        let options: [CGRect]
        let sendFrame: CGRect
        let scrollsHorizontally: Bool
        let scrollsVertically: Bool
        let firstLabel: String?
        let firstValue: String?
        let firstTraits: UIAccessibilityTraits
    }

    private func render(
        width: CGFloat,
        height: CGFloat,
        typeSize: DynamicTypeSize = .large
    ) async throws -> Rendered {
        let view = QuestionCardPager(count: 2, index: 0, cornerRadius: Constants.Conversation.Design.cornerRadius) { step in
            WorkspaceQuestionStepView(
                question: question,
                index: step,
                questionCount: 2,
                selectedIndices: [0],
                availableHeight: height,
                onSelect: { _ in },
                footer: footer
            )
        }
        .environment(\.dynamicTypeSize, typeSize)
        // This models the question region after the parent has already resolved safe areas.
        return try await SyntheticBadgeHost.render(view, width: width, height: height, safeAreaRegions: []) { hostView, _ in
            try inspect(hostView)
        }
    }

    private var question: Question {
        Question(
            attachmentId: "layout-question",
            header: "Choose a check",
            question: "Which check should run next?",
            explanation: nil,
            options: (1...4).map { index in
                QuestionOption(label: "Answer \(index)", description: "Run this check next.")
            }
        )
    }

    private var footer: some View {
        QuestionWizardFooterRow(
            index: 0,
            multiStep: false,
            isMulti: false,
            isLast: true,
            showNext: true,
            nextDisabled: false,
            submitted: false,
            dismissed: false,
            onBack: {},
            onSkip: {},
            onNext: {},
            usesWorkspaceDesign: true
        )
    }

    private func inspect(_ hostView: UIView) throws -> Rendered {
        let elements = SyntheticBadgeHost.accessibilityElements(in: hostView)
        let answerControls = elements.filter { element in
            SyntheticBadgeHost.accessibilityIdentifier(of: element)?.hasPrefix("question.option.") == true
        }
        #expect(answerControls.count == 4, "Only the active card's answers should be exposed to accessibility")
        let first = try #require(elements.first { element in
            SyntheticBadgeHost.accessibilityIdentifier(of: element) == "question.option.0"
        })
        let send = try #require(elements.first { element in
            SyntheticBadgeHost.accessibilityIdentifier(of: element) == "question.next"
        })
        let frames = (0..<4).compactMap { index in
            elements.first { element in
                SyntheticBadgeHost.accessibilityIdentifier(of: element) == "question.option.\(index)"
            }?.accessibilityFrame
        }
        let scrolls = scrollViews(in: hostView).filter { !$0.isHidden && !$0.bounds.isEmpty }
        return Rendered(
            hostFrame: hostView.convert(hostView.bounds, to: nil),
            options: frames,
            sendFrame: send.accessibilityFrame,
            scrollsHorizontally: scrolls.contains { $0.contentSize.width > $0.bounds.width + 1 },
            scrollsVertically: scrolls.contains { $0.contentSize.height > $0.bounds.height + 1 },
            firstLabel: first.accessibilityLabel,
            firstValue: first.accessibilityValue,
            firstTraits: first.accessibilityTraits
        )
    }

    private func scrollViews(in view: UIView) -> [UIScrollView] {
        ((view as? UIScrollView).map { [$0] } ?? [])
            + view.subviews.flatMap { scrollViews(in: $0) }
    }
}
