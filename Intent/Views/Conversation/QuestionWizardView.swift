import SwiftUI

/// Sequential Agent Q&A wizard rendered in the composer slot (FE parity:
/// `QuestionWizard.svelte` — borderless muted well, no card chrome). Walks
/// the pending questions one at a time; choose-one advances on selection,
/// multi-select keeps a Next button, return in the free-form field advances,
/// Skip clears + advances, Back returns with the previous answer preserved.
/// Ignore collapses the well to a compact re-expandable banner (transient —
/// the host owns the collapse flag; nothing is persisted). Dismiss (both the
/// expanded header and the collapsed banner carry it, when the host passes
/// `onDismiss`) retires the set PERSISTENTLY after a destructive confirmation
/// dialog — the host calls `agent.dismissQuestions`, which survives reload
/// (FE parity: DismissQuestionsConfirmDialog). On the last question Send
/// hands the full answers array to `onComplete`.
/// Single-question wizards hide the step counter, progress segments, and
/// Back button. The host remounts the wizard (`.id` on the question-bearing
/// message id) whenever a different question set pends.
struct QuestionWizardView: View {
    let questions: [Question]
    /// Host-owned Ignore state — true renders the compact banner.
    @Binding var collapsed: Bool
    let onComplete: ([QuestionAnswer]) -> Void
    /// Persistent dismissal — host calls `agent.dismissQuestions`. The
    /// Dismiss affordance renders only when present.
    var onDismiss: (() -> Void)? = nil

    @Environment(\.colorScheme) private var colorScheme

    private struct DraftAnswer {
        var sel: [Int] = []
        var text: String = ""
        var skipped: Bool = false
    }

    @State private var idx = 0
    @State private var drafts: [DraftAnswer]
    /// One-shot completion guard — the last-step Send button stays mounted
    /// (and tappable) until the host reacts to `onComplete`, so rapid
    /// double-taps must not submit duplicate answer messages.
    @State private var submitted = false
    /// Destructive-confirmation gate for Dismiss.
    @State private var confirmingDismiss = false
    /// One-shot dismissal guard (PR #86 review) — set synchronously when the
    /// user confirms Dismiss, before the host's async `agent.dismissQuestions`
    /// hop, so a Send (or a second Dismiss) can no longer race the in-flight
    /// dismissal and discard an answer / duplicate the daemon notice. The host
    /// unmounts the wizard when the dismissal marker lands; a failed RPC
    /// remounts it fresh (`.id`-keyed), which resets this flag.
    @State private var dismissed = false
    /// Measured natural height of the step content — the scrollable body hugs
    /// short steps (no empty filler) and caps at `stepBodyMaxHeight`.
    @State private var stepContentHeight: CGFloat = 0

    init(
        questions: [Question],
        collapsed: Binding<Bool>,
        onComplete: @escaping ([QuestionAnswer]) -> Void,
        onDismiss: (() -> Void)? = nil
    ) {
        self.questions = questions
        self._collapsed = collapsed
        self.onComplete = onComplete
        self.onDismiss = onDismiss
        _drafts = State(initialValue: questions.map { _ in DraftAnswer() })
    }

    // MARK: - Derived state (FE parity)

    private var current: Question { questions[idx] }
    private var isLast: Bool { idx == questions.count - 1 }
    private var isMulti: Bool { current.multiSelect }
    /// Single-question wizards drop the counter, segments, and Back button.
    private var multiStep: Bool { questions.count > 1 }
    /// Single-select mid-flow advances on selection — no Next button.
    private var showNext: Bool { isMulti || isLast }
    private var nextDisabled: Bool {
        (isMulti || isLast) && drafts[idx].sel.isEmpty
            && drafts[idx].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if questions.isEmpty {
                EmptyView()
            } else if collapsed {
                collapsedBanner
            } else {
                headerRow
                stepBody
                    .id(idx)
                    .transition(.opacity)
                footerRow
            }
        }
        .background(Theme.muted(for: colorScheme).opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Theme.border(for: colorScheme).opacity(0.3), lineWidth: 1)
        )
        .animation(.easeInOut(duration: 0.15), value: idx)
        .animation(.easeInOut(duration: 0.15), value: collapsed)
        .confirmationDialog(
            "Dismiss questions?",
            isPresented: $confirmingDismiss,
            titleVisibility: .visible
        ) {
            Button("Dismiss questions", role: .destructive) {
                guard !dismissed && !submitted else { return }
                dismissed = true
                onDismiss?()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "The agent's questions will be dismissed completely without "
                    + "answering. This is permanent — they won't come back, "
                    + "even after a reload.")
        }
    }

    // MARK: - Actions (FE parity)

    private func buildAnswers() -> [QuestionAnswer] {
        zip(questions, drafts).map { question, draft in
            QuestionAnswer(
                question: question,
                selectedLabels: draft.sel.map { question.options[$0].label },
                freeText: draft.text.trimmingCharacters(in: .whitespacesAndNewlines),
                skipped: draft.skipped
            )
        }
    }

    private func advance() {
        if idx >= questions.count - 1 {
            guard !submitted && !dismissed else { return }
            submitted = true
            onComplete(buildAnswers())
            return
        }
        idx += 1
    }

    private func selectOption(_ oi: Int) {
        if isMulti {
            if let pos = drafts[idx].sel.firstIndex(of: oi) {
                drafts[idx].sel.remove(at: pos)
            } else {
                drafts[idx].sel.append(oi)
            }
            drafts[idx].skipped = false
            return
        }
        drafts[idx].sel = drafts[idx].sel.contains(oi) ? [] : [oi]
        drafts[idx].skipped = false
        if isLast { return }
        advance()
    }

    private func handleNext() {
        if nextDisabled { return }
        advance()
    }

    private func handleSkip() {
        drafts[idx].sel = []
        drafts[idx].text = ""
        drafts[idx].skipped = true
        advance()
    }

    private func handleBack() {
        idx = max(idx - 1, 0)
    }

    // MARK: - Collapsed banner (Ignore state)

    /// Tap re-expands; Dismiss is a sibling button (FE parity: the
    /// hide-collapsed banner keeps the persistent-dismiss affordance).
    @ViewBuilder
    private var collapsedBanner: some View {
        HStack(spacing: 0) {
            Button {
                collapsed = false
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "questionmark.circle")
                        .font(.caption)
                        .foregroundStyle(Theme.primary(for: colorScheme))
                    Text("Questions")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Theme.foreground(for: colorScheme))
                    Text("\(questions.count)")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Theme.foreground(for: colorScheme))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Theme.primary(for: colorScheme).opacity(0.12)))
                        .overlay(
                            Capsule().strokeBorder(
                                Theme.primary(for: colorScheme).opacity(0.35), lineWidth: 1)
                        )
                    Spacer(minLength: 8)
                    Text("Tap to expand")
                        .font(.caption2)
                        .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if onDismiss != nil {
                dismissButton
                    .padding(.trailing, 8)
            }
        }
    }

    /// Opens the destructive confirmation; the dismissal itself is persistent
    /// (host calls `agent.dismissQuestions`), unlike the transient Ignore.
    @ViewBuilder
    private var dismissButton: some View {
        Button {
            confirmingDismiss = true
        } label: {
            Text("Dismiss")
                .font(.caption)
                .foregroundStyle(Theme.destructive(for: colorScheme))
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(dismissed)
        .opacity(dismissed ? 0.5 : 1)
    }

    // MARK: - Header row

    @ViewBuilder
    private var headerRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "questionmark.circle")
                .font(.caption)
                .foregroundStyle(Theme.primary(for: colorScheme))
            Text("Questions")
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.foreground(for: colorScheme))
            if multiStep {
                Text("\(idx + 1) of \(questions.count)")
                    .font(.caption)
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                HStack(spacing: 4) {
                    ForEach(questions.indices, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(segmentColor(i))
                            .frame(width: 14, height: 4)
                    }
                }
            }
            if isMulti {
                Text("Select all that apply")
                    .font(.caption2)
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Theme.muted(for: colorScheme).opacity(0.8)))
            }
            Spacer(minLength: 8)
            Button {
                collapsed = true
            } label: {
                Text("Ignore")
                    .font(.caption)
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
            }
            .buttonStyle(.plain)
            if onDismiss != nil {
                dismissButton
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
    }

    private func segmentColor(_ i: Int) -> Color {
        if i < idx { return Theme.primary(for: colorScheme).opacity(0.4) }
        if i == idx { return Theme.primary(for: colorScheme) }
        return Theme.mutedForeground(for: colorScheme).opacity(0.25)
    }

    // MARK: - Step body

    /// Cap the scrollable step body at ~half the screen so the header/footer
    /// rows and the transcript above stay visible under a long question set.
    /// Deliberate iOS-specific divergence from FE parity: the desktop
    /// `QuestionWizard.svelte` renders the step body at natural height with
    /// no cap — on a phone that would push the transcript and footer
    /// offscreen, so the body scrolls under this cap instead.
    private var stepBodyMaxHeight: CGFloat { UIScreen.main.bounds.height * 0.5 }

    /// Long steps scroll inside the capped ScrollView; short steps keep their
    /// natural height (the frame caps at the measured content height, so the
    /// well never pads out with empty filler).
    @ViewBuilder
    private var stepBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(current.header.uppercased())
                        .font(.caption2.weight(.semibold))
                        .kerning(0.5)
                        .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(current.question)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.foreground(for: colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(spacing: 6) {
                    ForEach(current.options.indices, id: \.self) { oi in
                        optionButton(oi)
                    }
                }
                otherField
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 8)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { height in
                stepContentHeight = height
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(
            maxHeight: stepContentHeight > 0
                ? min(stepContentHeight, stepBodyMaxHeight)
                : stepBodyMaxHeight
        )
    }

    @ViewBuilder
    private func optionButton(_ oi: Int) -> some View {
        let option = current.options[oi]
        let selected = drafts[idx].sel.contains(oi)
        Button {
            selectOption(oi)
        } label: {
            HStack(spacing: 10) {
                if isMulti {
                    checkbox(selected)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.label)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Theme.foreground(for: colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                    if let description = option.description {
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                if !isMulti {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.mutedForeground(for: colorScheme).opacity(0.6))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                selected
                    ? Theme.primary(for: colorScheme).opacity(0.1)
                    : Theme.background(for: colorScheme).opacity(0.6)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        selected
                            ? Theme.primary(for: colorScheme)
                            : Theme.border(for: colorScheme).opacity(0.4),
                        lineWidth: 1
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func checkbox(_ selected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(selected ? Theme.primary(for: colorScheme) : Color.clear)
            .frame(width: 15, height: 15)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(
                        selected
                            ? Color.clear
                            : Theme.mutedForeground(for: colorScheme).opacity(0.5),
                        lineWidth: 1
                    )
            )
            .overlay {
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
    }

    /// Always-visible free-form "Other" input; return advances.
    @ViewBuilder
    private var otherField: some View {
        HStack(spacing: 8) {
            Image(systemName: "pencil")
                .font(.system(size: 11))
                .foregroundStyle(Theme.mutedForeground(for: colorScheme).opacity(0.6))
            TextField("Type your own answer…", text: $drafts[idx].text)
                .font(.body)
                .foregroundStyle(Theme.foreground(for: colorScheme))
                .onSubmit { handleNext() }
                .onChange(of: drafts[idx].text) { _, _ in
                    drafts[idx].skipped = false
                }
            Image(systemName: "return")
                .font(.caption2)
                .foregroundStyle(Theme.mutedForeground(for: colorScheme).opacity(0.5))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Theme.background(for: colorScheme).opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Footer row

    @ViewBuilder
    private var footerRow: some View {
        HStack(spacing: 8) {
            if multiStep {
                Button {
                    handleBack()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 9, weight: .semibold))
                        Text("Back")
                            .font(.caption)
                    }
                    .foregroundStyle(
                        Theme.mutedForeground(for: colorScheme)
                            .opacity(idx == 0 ? 0.4 : 1)
                    )
                }
                .buttonStyle(.plain)
                .disabled(idx == 0)
            }
            if !isMulti && !isLast {
                Text("Selecting an option advances")
                    .font(.caption2)
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme).opacity(0.6))
            }
            Spacer(minLength: 8)
            Button {
                handleSkip()
            } label: {
                Text("Skip")
                    .font(.caption)
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
            }
            .buttonStyle(.plain)
            if showNext {
                Button {
                    handleNext()
                } label: {
                    HStack(spacing: 4) {
                        Text(isLast ? "Send" : "Next")
                            .font(.caption.weight(.semibold))
                        Image(systemName: isLast ? "arrow.up" : "arrow.right")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Theme.primary(for: colorScheme)))
                }
                .buttonStyle(.plain)
                .disabled(nextDisabled || submitted || dismissed)
                .opacity(nextDisabled || submitted || dismissed ? 0.5 : 1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 2)
        .padding(.bottom, 12)
    }
}
