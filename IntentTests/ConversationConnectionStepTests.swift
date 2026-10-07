@testable import Intent
import Testing

struct ConversationConnectionStepTests {
    @Test(arguments: [
        (ConversationLiveTranscript.LoadingStage.idle, ConversationConnectionStep.connecting),
        (.connecting, .connecting),
        (.requesting, .requesting),
        (.receiving, .receiving),
        (.retrying(attempt: 1), .requesting),
        (.retrying(attempt: 3), .requesting)
    ])
    func stepsTrackProgressIncludingRetries(
        stage: ConversationLiveTranscript.LoadingStage, expectedStep: ConversationConnectionStep
    ) {
        #expect(ConversationConnectionStep(stage: stage) == expectedStep)
    }
}
