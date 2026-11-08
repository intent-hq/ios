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
            await settle(host)
            #expect(attachments.pendingImages.count == 1)
            #expect(attachments.pendingFiles.count == 1)
            model.store.isStreaming = false
            await settle(host)
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
            await settle(host)
            #expect(!attachments.hasPendingAttachments)
            #expect(model.questionAttachmentPipelines[question.id] == nil)
        }
    }

    private func settle(_ host: UIView) async {
        for _ in 0..<5 {
            host.layoutIfNeeded()
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
}
