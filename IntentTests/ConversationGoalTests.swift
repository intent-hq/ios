import Foundation
@testable import Intent
import Testing

@MainActor
struct ConversationGoalTests {
    @Test(arguments: [
        ("/goal x", true),
        ("  /goal\nx", true),
        ("/goal", true),
        ("\t/goal  ", true),
        ("/goal\tship it", true),
        ("\u{3000}/goal\u{00A0}ship it\u{2029}", true),
        ("/goal\u{0085}ship it", true),
        ("/goal\u{200B}ship it", false),
        ("/Goal x", false),
        ("/goals x", false),
        ("/goal: x", false),
        ("please /goal x", false),
        ("", false)
    ])
    func recognizesTheDaemonCommandShape(content: String, isCommand: Bool) {
        #expect(ConversationGoal.isCommand(content) == isCommand)
    }

    @Test func capabilityRequiresExactVersionOne() {
        func capabilities(_ value: Any?) -> ConnectionCapabilities {
            var advertised: [String: Any] = [:]
            if let value { advertised["conversationGoal"] = value }
            return ConnectionCapabilities(hello: ["server": ["protocolVersion": ProtocolFixtures.currentProtocolVersion, "capabilities": advertised]])
        }
        #expect(capabilities(1).supportsConversationGoal)
        #expect(!capabilities(nil).supportsConversationGoal)
        #expect(!capabilities(2).supportsConversationGoal)
        #expect(!capabilities(true).supportsConversationGoal)
        #expect(!ConnectionCapabilities.unknown.supportsConversationGoal)
    }

    @Test func agentRowsReadGoalAndTreatAbsentAsUnset() {
        let withGoal = AgentSession.parseAgent(["id": "a", "name": "A", "goal": "Ship it"])
        let without = AgentSession.parseAgent(["id": "a", "name": "A"])
        let null = AgentSession.parseAgent(["id": "a", "name": "A", "goal": NSNull()])
        #expect(withGoal?.goal == "Ship it")
        #expect(without?.goal == nil)
        #expect(null?.goal == nil)
        #expect(withGoal?.applyingPreview(lastAgentResponse: "hi", digest: nil).goal == "Ship it")
    }

    @Test func linkedTextMarksOnlyWebLinks() {
        let goal = "Track https://github.com/intent-hq/intent/issues/9646 and mail me@example.com"
        let links = ConversationGoal.links(in: goal)
        #expect(links.map(\.absoluteString) == ["https://github.com/intent-hq/intent/issues/9646"])
        #expect(String(ConversationGoal.linkedText(goal).characters) == goal)
    }

    @Test func normalizedTrimsAndTreatsBlankAsRemoval() {
        #expect(ConversationGoal.normalized("  Ship it \n") == "Ship it")
        #expect(ConversationGoal.normalized(" \n ") == nil)
        #expect(ConversationGoal.normalized("\u{3000}Ship it\u{0085}") == "Ship it")
        #expect(ConversationGoal.normalized("\u{200B}Ship it") == "\u{200B}Ship it", "Zero-width space is not White_Space")
        #expect(ConversationGoal.length("  e\u{301} ") == 2, "Length counts Unicode scalar values after trimming")
    }

    @Test func failureMessagesBranchOnTheDataCode() {
        func failure(_ code: String?, _ message: String = "daemon text") -> NSError {
            var info: [String: Any] = [NSLocalizedDescriptionKey: message]
            if let code { info[NSError.intentErrorDataCodeKey] = code }
            return NSError(domain: "WebSocket", code: -32_602, userInfo: info)
        }
        #expect(ConversationGoal.failureMessage(for: failure("goal-too-long")) == ConversationGoal.tooLongError)
        #expect(ConversationGoal.failureMessage(for: failure("goal-attachments-not-allowed")) == ConversationGoal.attachmentsError)
        #expect(ConversationGoal.failureMessage(for: failure("agent-retired")) == ConversationGoal.retiredError)
        #expect(ConversationGoal.failureMessage(for: failure(nil, "agent not found")) == "The goal was not changed. agent not found")
        #expect(ConversationGoal.failureMessage(for: failure(nil, " ")) == "The goal was not changed. Try again.")
    }

    @Test func commandResultsParseBothResponseShapes() {
        let command = GoalCommandResult(command: ["name": "goal", "action": "set", "goal": "Ship it", "noticeMessageId": "n1"])
        #expect(command == GoalCommandResult(action: "set", goal: "Ship it", noticeMessageId: "n1"))
        #expect(GoalCommandResult(command: ["name": "other", "action": "set"]) == nil)
        #expect(GoalCommandResult(command: nil) == nil)
        let cleared = GoalCommandResult(setGoalResponse: ["action": "cleared", "goal": NSNull(), "noticeMessageId": "n2"])
        #expect(cleared == GoalCommandResult(action: "cleared", goal: nil, noticeMessageId: "n2"))
        #expect(GoalCommandResult(setGoalResponse: ["goal": "x"]) == nil)
    }

    @Test func goalCommandRowsBecomeGoalNotices() throws {
        let row = ConversationMessage.parseMessage([
            "id": "n1", "role": "system",
            "contentBlocks": [["type": "text", "text": "Goal set: Ship it"]],
            "metadata": ["type": "goal_command", "action": "set", "goal": "Ship it"]
        ])
        let notice = try #require(row?.goalCommandNotice)
        #expect(notice == GoalCommandNotice(action: .set, goal: "Ship it", text: "Goal set: Ship it"))
        #expect(notice.label == "Goal set: Ship it")
        #expect(row?.modelChangeNotice == nil)
    }

    @Test func goalNoticeIgnoresOtherRows() {
        let other = ConversationMessage.parseMessage([
            "id": "n2", "role": "system",
            "contentBlocks": [["type": "text", "text": "Something"]],
            "metadata": ["type": "model_changed"]
        ])
        let user = ConversationMessage.parseMessage([
            "id": "n3", "role": "user",
            "contentBlocks": [["type": "text", "text": "Goal set: x"]],
            "metadata": ["type": "goal_command", "action": "set"]
        ])
        #expect(other?.goalCommandNotice == nil)
        #expect(user?.goalCommandNotice == nil)
    }

    @Test(arguments: [
        (GoalCommandNotice.Action.set, String?.some("Ship"), "Goal set: Ship"),
        (.updated, "Ship", "Goal updated: Ship"),
        (.unchanged, "Ship", "Goal unchanged: Ship"),
        (.cleared, nil, "Goal removed."),
        (.shown, "Ship", "Current goal: Ship"),
        (.shown, nil, "No goal set. Send /goal followed by what done looks like.")
    ])
    func noticeLabelFallsBackToActionWhenTextIsMissing(action: GoalCommandNotice.Action, goal: String?, label: String) {
        #expect(GoalCommandNotice(action: action, goal: goal, text: " ").label == label)
    }

    @Test func stripStateExpandsAndCollapses() {
        var state = ConversationGoalStripState.collapsed
        state.toggleExpansion()
        #expect(state.isExpanded)
        state.toggleExpansion()
        #expect(state == .collapsed)
    }

    @Test func stripStateEditsCancelsAndSaves() {
        var state = ConversationGoalStripState.expanded
        state.beginEditing(goal: "Ship it")
        #expect(state.isEditorPresented)
        #expect(state.draft?.text == "Ship it")
        state.toggleExpansion()
        #expect(state.isEditorPresented, "Expansion is frozen while editing")
        state.cancelEditing()
        #expect(state == .collapsed)

        state.beginEditing(goal: "Ship it")
        state.updateDraft("Ship the beta")
        #expect(state.beginSaving() == "Ship the beta")
        #expect(state.isSaving)
        #expect(!state.canSave)
        #expect(state.beginSaving() == nil, "A second save waits for the first")
        state.cancelEditing()
        #expect(state.isSaving, "Cancel is ignored while saving")
        state.finishSaving(failure: nil)
        #expect(state == .collapsed)
    }

    @Test func stripStateKeepsDraftAndShowsFailure() {
        var state = ConversationGoalStripState.collapsed
        state.beginEditing(goal: "Ship it")
        state.updateDraft("")
        #expect(state.beginSaving()?.isEmpty == true, "Saving an empty draft removes the goal")
        state.finishSaving(failure: "The goal was not changed.")
        #expect(state == .editing(ConversationGoalDraft(text: "", failure: "The goal was not changed.")))
        state.updateDraft("Again")
        #expect(state.draft?.failure == nil, "Typing clears the failure")
    }

    @Test func stripStateGuardsRemoval() {
        var state = ConversationGoalStripState.expanded
        #expect(state.beginRemoving())
        #expect(state.isRemoving)
        #expect(!state.beginRemoving(), "A second tap while removing is ignored")
        state.toggleExpansion()
        state.beginEditing(goal: "Ship it")
        #expect(state == .removing, "Expanding and editing wait for the removal")
        state.finishRemoving()
        #expect(state == .collapsed)
        state.beginEditing(goal: "Ship it")
        #expect(!state.beginRemoving(), "Removing is unavailable while the editor is open")
    }

    @Test func stripStateLeavesTheLengthCheckToTheDaemon() {
        var state = ConversationGoalStripState.collapsed
        let long = String(repeating: "a", count: ConversationGoal.maximumLength + 1)
        state.beginEditing(goal: long)
        #expect(state.canSave)
        #expect(state.beginSaving() == long)
        state.finishSaving(failure: ConversationGoal.tooLongError)
        #expect(state.draft == ConversationGoalDraft(text: long, failure: ConversationGoal.tooLongError))
    }
}
