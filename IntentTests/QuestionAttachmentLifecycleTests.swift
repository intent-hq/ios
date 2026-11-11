@testable import Intent
import SwiftUI
import Testing
import UIKit

@MainActor
@Suite(.serialized)
struct QuestionAttachmentLifecycleTests {
    @Test(arguments: ["cleared", "dismissed", "answered", "superseded", "legacy"])
    func remoteRetirementClearsSelectionButStreamingDoesNot(retirement: String) async throws {
        let model = ConversationViewModelTests().makeVM()
        let question = ConversationViewModelTests().questionMessage()
        model.store.messages = [question]
        let view = Text("Conversation").modifier(QuestionAttachmentLifecycle(viewModel: model))
        try await SyntheticBadgeHost.render(view, width: 390, height: 200) { host, _ in
            // Allocate after mounting to exercise observation before a pipeline exists.
            let attachments = model.questionAttachments(for: question.id)
            attachments.addImage(try #require(UIImage(systemName: "star")))
            attachments.addFiles([URL(fileURLWithPath: "/tmp/question-answer.txt")])
            model.store.isStreaming = true
            try await expectNoRetirement(attachments, host: host, "retirement while streaming")
            #expect(attachments.pendingImages.count == 1)
            #expect(attachments.pendingFiles.count == 1)
            model.store.isStreaming = false
            try await expectNoRetirement(attachments, host: host, "retirement when streaming ends")
            #expect(attachments.hasPendingAttachments)

            switch retirement {
            case "cleared": model.store.pendingQuestionsMessageId = ""
            case "dismissed": model.store.dismissedQuestionsMessageId = question.id
            case "superseded": model.store.pendingQuestionsMessageId = "new-question"
            case "answered":
                var answer = ConversationViewModelTests().textMessage(role: .user, text: "Answered elsewhere")
                answer.metadata = ["type": AnyCodable("question_answers"), "answeredQuestionsMessageId": AnyCodable(question.id)]
                model.store.messages.append(answer)
            default:
                model.store.messages.append(ConversationViewModelTests().textMessage(role: .user, text: "New turn"))
            }
            try await waitUntil("\(retirement) question to discard its attachments") {
                host.layoutIfNeeded()
                return !attachments.hasPendingAttachments && model.questionAttachmentPipelines[question.id] == nil
            }
            #expect(!attachments.hasPendingAttachments)
            #expect(model.questionAttachmentPipelines[question.id] == nil)
        }
    }

    /// Negative window: the lifecycle must leave the selection alone, and
    /// there is no event to await for something that should not happen, so
    /// poll (with layout passes) through `expectNever`'s bounded window.
    private func expectNoRetirement(
        _ attachments: ConversationAttachmentPipeline,
        host: UIView,
        _ description: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        try await expectNever(description, sourceLocation: sourceLocation) {
            host.layoutIfNeeded()
            return !attachments.hasPendingAttachments
        }
    }
}
