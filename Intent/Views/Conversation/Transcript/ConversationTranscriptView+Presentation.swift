import SwiftUI

// These builders remain on the transcript so extraction does not add a new
// observation boundary or change the lazy stack's row and anchor identities.
extension ConversationTranscriptView {
    private static let eagerTailMessageLimit = 12

    @ViewBuilder
    func transcriptRows(proxy: ScrollViewProxy, dividerAnchorId: String?) -> some View {
        let generation = scrollState.initialScrollGeneration
        let ownershipRevision = scrollState.viewportOwnershipRevision
        // Snapshot hydration, cached heights and workspace inputs on MainActor.
        // SwiftUI may request these prepared row values on its render thread.
        let messages = viewModel.filteredMessages
        let rows = messages.enumerated().map { index, message in
            (id: message.id, content: transcriptMessageRow(
                for: message,
                proxy: proxy,
                dividerAnchorId: dividerAnchorId,
                generation: generation,
                ownershipRevision: ownershipRevision
            ).padding(.top, messageSpacing(at: index, in: messages)))
        }
        if viewModel.olderMessagesError != nil || !viewModel.hasOlderMessages {
            olderMessagesRow(proxy: proxy)
                .id("older-messages")
        }

        ForEach(rows.dropLast(Self.eagerTailMessageLimit), id: \.id) { @Sendable row in
            row.content
        }
        // Realize a bounded tail and its footer together. A separately lazy
        // footer can remain absent at the stack's estimated bottom after
        // rows resize, even when repeated scrollTo calls land.
        VStack(spacing: 0) {
            ForEach(rows.suffix(Self.eagerTailMessageLimit), id: \.id) { @Sendable row in
                row.content
            }
            transcriptEndRows(proxy: proxy)
                .padding(.top, transcriptRowSpacing)
        }
        .id("transcript-tail")
    }

    private func messageSpacing(at index: Int, in messages: [ConversationMessage]) -> CGFloat {
        guard index > 0 else {
            return viewModel.olderMessagesError != nil || !viewModel.hasOlderMessages ? transcriptRowSpacing : 0
        }
        if isMessageTrace(messages[index - 1]), isMessageTrace(messages[index]) {
            return Constants.Conversation.Design.Transcript.toolRowSpacing
        }
        return transcriptRowSpacing
    }

    private func isMessageTrace(_ message: ConversationMessage) -> Bool {
        message.role == .user
            && (message.agentMessageAttribution != nil || message.eventWakeAttribution != nil)
    }

    @ViewBuilder
    private func transcriptEndRows(proxy: ScrollViewProxy) -> some View {
        #if !os(visionOS)
        // On visionOS the composer renders these as large chips above the
        // field instead (MessageInputView).
        if !viewModel.suggestedPrompts.isEmpty, !viewModel.isStreaming {
            suggestedPromptsView
                .id("suggested-prompts")
        }
        #endif

        if viewModel.isStreaming {
            thinkingIndicatorView
                .transition(.move(edge: .top).combined(with: .opacity))
                .id("thinking-indicator")
        }

        // The stack's bottom padding lives on the marker so that
        // `scrollTo("scroll-bottom", anchor: .bottom)` targets the true end
        // of the content, not a point 12 points above it that a landing
        // judged against `followLandingTolerance` could never reach. A
        // floating launcher's `bottomClearance` lives here for the same
        // reason. Its realization is the end-row signal the unrealized-end recovery
        // reads (#338): the lazy stack appears and disappears the marker as
        // it realizes and drops it. Realizing while scrolled away replays
        // the live edge; derealizing arms the recovery.
        if demoWithdrawnEnd == nil {
            Color.clear.frame(height: Layout.bottomAnchorHeight)
                .padding(.bottom, Layout.bottomAnchorPadding + bottomClearance)
                .id("scroll-bottom")
                .onGeometryChange(for: CGRect.self) { geometry in
                    ConversationTrace.enabled ? geometry.frame(in: .named(Self.viewportCoordinateSpace)) : .zero
                } action: { frame in
                    scrollState.trace.recordEnd(frame)
                    traceEvent("EndGeometry", "frame=\(frame)")
                }
                .onAppear {
                    send(.endRealized(userIsScrolledAway: userIsScrolledAway), proxy: proxy)
                }
                .onDisappear {
                    scrollState.trace.recordEnd(nil)
                    send(.endDerealized, proxy: proxy)
                }
        } else {
            // Demo-only stand-in while the marker is withdrawn (see
            // `withdrawEndRowForDemo`): the same height, so the content
            // height and every offset the recovery reads are unchanged, but
            // no id and no realization handlers — `scrollTo("scroll-bottom")`
            // finds nothing and `isEndRealized` stays false, exactly as over
            // a dropped end row.
            Color.clear.frame(height: Layout.bottomAnchorHeight)
                .padding(.bottom, Layout.bottomAnchorPadding + bottomClearance)
        }
    }

    private func transcriptMessageRow(
        for message: ConversationMessage,
        proxy: ScrollViewProxy,
        dividerAnchorId: String?,
        generation: Int,
        ownershipRevision: Int
    ) -> some View {
        let marker = restorationMarker(for: message.id)
        // One stable lazy-stack target per message. A late divider changes
        // its height without shifting the identity of all following rows.
        return VStack(spacing: Layout.transcriptRowSpacing) {
            messageRow(for: message)
            if message.id == dividerAnchorId {
                entryDivider(dividerAnchorId: dividerAnchorId, generation: generation, ownershipRevision: ownershipRevision)
            }
        }
        .id(message.id)
        // Pass the prepared marker directly, without a render-thread closure capture (#737).
        .overlay(marker, alignment: .top)
        .onGeometryChange(for: ConversationTranscriptViewportAnchor.Measurement.self) { geometry in
            .init(frame: geometry.frame(in: .named(Self.viewportCoordinateSpace)), divider: dividerAnchorId, generation: generation, ownershipRevision: ownershipRevision)
        } action: { measurement in
            scrollState.trace.row(message.id, frame: measurement.frame, context: traceContext)
            preserveRowOffsetAfterDividerChange(messageId: message.id, measurement: measurement, proxy: proxy)
        }
        .onDisappear {
            traceEvent("RowDisappeared", "row=\(message.id)")
            scrollState.trace.removeRow(message.id)
            scrollState.viewportAnchor.remove(id: message.id, generation: generation, entryGeneration: scrollState.initialScrollGeneration, ownershipRevision: ownershipRevision)
        }
    }

    private func restorationMarker(for messageId: String) -> some View {
        // A realized row's top marker lets SwiftUI own the final retained
        // offset even for partial or viewport-sized rows, without layout space.
        Color.clear
            .frame(height: ConversationTranscriptViewportAnchor.restorationMarkerHeight)
            .id(ConversationTranscriptViewportAnchor.RestorationTarget(messageID: messageId))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private func entryDivider(dividerAnchorId: String?, generation: Int, ownershipRevision: Int) -> some View {
        NewMessagesDividerView()
            .id("new-messages-divider")
            .onGeometryChange(for: ConversationTranscriptViewportAnchor.Measurement.self) { geometry in
                .init(frame: geometry.frame(in: .named(Self.viewportCoordinateSpace)), divider: dividerAnchorId, generation: generation, ownershipRevision: ownershipRevision)
            } action: { measurement in
                guard lifecycle.isVisible, !isUserInteracting, !isFollowing,
                      let geometry = scrollMomentumProxy.restingGeometry,
                      let adjustment = scrollState.entryDividerAdjustment(measurement, viewportHeight: geometry.containerHeight) else { return }
                scrollMomentumProxy.pageTo(offsetY: geometry.contentOffsetY + adjustment)
            }
    }

    private func preserveRowOffsetAfterDividerChange(
        messageId: String, measurement: ConversationTranscriptViewportAnchor.Measurement, proxy: ScrollViewProxy
    ) {
        guard lifecycle.isVisible else { return }
        // This live check also covers a queued callback that beats the
        // column's message-ID observer after an authoritative deletion.
        scrollState.retainViewportMessages(withIDs: viewModel.filteredMessageIDs)
        guard measurement.divider == viewModel.newMessagesDividerAnchorId,
              let geometry = scrollMomentumProxy.restingGeometry else { return }
        // The geometry callback includes the divider identity, so even a row
        // already held by bottom anchoring consumes this revision with no move.
        let application = scrollState.viewportAnchor.application(
            id: messageId,
            measurement: measurement,
            geometry: geometry,
            preserve: hasInitiallyScrolled && !isUserInteracting && !isFollowing,
            entryGeneration: scrollState.initialScrollGeneration
        )
        switch application {
        case .offset(let offset):
            traceEvent("RowRestoration", "row=\(messageId) offset=\(offset)")
            scrollMomentumProxy.pageTo(offsetY: offset)
        case let .retainedAlignment(target, anchorY, rowY):
            traceEvent("RowRestoration", "row=\(messageId) target=\(target) anchor=\(anchorY) rowY=\(rowY)")
            proxy.scrollTo(target, anchor: UnitPoint(x: 0.5, y: anchorY))
            scrollState.viewportAnchor.recordRestorationAlignment(
                anchorY: anchorY,
                rowY: rowY,
                before: geometry.contentOffsetY,
                immediate: scrollMomentumProxy.restingGeometry?.contentOffsetY
            )
        case nil:
            break
        }
    }

    private func messageRow(for message: ConversationMessage) -> some View {
        let hydratingBlockIds = viewModel.store.hydratingBlockIds(forMessage: message.id)
        let cachedHeight = scrollState.rowHeightCache.height(
            for: message,
            hydratingBlockIds: hydratingBlockIds
        )
        return MessageView(
            message: message,
            workspaceId: viewModel.workspaceId,
            onNavigateToNote: onNavigateToNote,
            onNavigateToAgent: onNavigateToAgent,
            hydratingBlockIds: hydratingBlockIds,
            onLayoutChange: {
                scrollState.rowHeightCache.invalidate(messageId: message.id)
            },
            onHydrateBlock: { blockId in
                let messageId = message.id
                Task {
                    await viewModel.store.hydrateBlock(
                        messageId: messageId,
                        blockId: blockId
                    )
                }
            }
        )
        .environment(\.transcriptDisclosureState, scrollState.disclosures.state(for: message.id))
        .modifier(
            ConversationTranscriptRowHeightFrame(
                cachedHeight: cachedHeight,
                isStreaming: message.isStreaming
            ) { height in
                traceEvent("RowHeight", "row=\(message.id) natural=\(height) cached=\(String(describing: cachedHeight)) streaming=\(message.isStreaming)")
                scrollState.rowHeightCache.record(
                    height: height,
                    for: message,
                    hydratingBlockIds: hydratingBlockIds,
                    retainingMessagesWithIDs: viewModel.filteredMessageIDs
                )
            }
        )
    }

    func goToEndButton(proxy: ScrollViewProxy) -> some View {
        Button {
            traceSnapshot("goToEndTap")
            scheduleTraceSnapshots()
            scrollMomentumProxy.stopMomentum()
            claimViewportForExplicitFollow(proxy: proxy)
            scrollState.isScrollingToBottom = true
            scrollState.goToEndRequested = true
            scrollState.userIsScrolledAway = false
        } label: {
            goToEndLabel
        }
        .buttonStyle(IntentContentButtonStyle())
        .accessibilityIdentifier("transcript.goToEnd")
        .padding(.bottom, Layout.goToEndBottomPadding)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
        .animation(
            .easeInOut(duration: Constants.Conversation.Transcript.goToEndVisibilityAnimationDuration),
            value: userIsScrolledAway
        )
    }

    @ViewBuilder
    private var goToEndLabel: some View {
        if usesWorkspaceDesign {
            WorkspaceGoToEndLabel()
        } else {
            HStack(spacing: Layout.goToEndSpacing) {
                Image(.chevronDown)
                    .resizable()
                    .scaledToFit()
                    .frame(width: actionIconSide, height: actionIconSide)
                Text("Go to End")
                    .interFont(Constants.Typography.subtextXXS.withFace(.medium))
            }
            .padding(.horizontal, Layout.goToEndHorizontalPadding)
            .padding(.vertical, Layout.goToEndVerticalPadding)
            .background(.ultraThinMaterial)
            .clipShape(Capsule())
            .shadow(
                color: .black.opacity(Layout.goToEndShadowOpacity),
                radius: Layout.goToEndShadowRadius,
                y: Layout.goToEndShadowYOffset
            )
        }
    }

    @ViewBuilder
    private var thinkingIndicatorView: some View {
        if usesWorkspaceDesign {
            WorkspaceThinkingLabel(title: "Thinking...", showsDisclosure: false)
                .padding(.vertical, Layout.thinkingIndicatorVerticalPadding)
        } else {
            legacyThinkingIndicatorView
        }
    }

    private var legacyThinkingIndicatorView: some View {
        HStack(spacing: Layout.thinkingIndicatorSpacing) {
            ProgressView()
                .scaleEffect(Layout.thinkingIndicatorScale)
                .frame(width: Layout.thinkingIndicatorSide, height: Layout.thinkingIndicatorSide)
            Text("Thinking...")
                .interFont(Constants.Typography.subtextXXS)
                .foregroundStyle(Theme.mutedForeground(for: transcriptColorScheme))
        }
        .padding(.horizontal, Layout.thinkingIndicatorHorizontalPadding)
        .padding(.vertical, Layout.thinkingIndicatorVerticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    #if !os(visionOS)
    private var suggestedPromptsView: some View {
        VStack(spacing: Layout.suggestedPromptSpacing) {
            ForEach(Array(viewModel.suggestedPrompts.enumerated()), id: \.element) { index, prompt in
                suggestedPromptButton(prompt)
                    .accessibilityIdentifier("transcript.suggestedPrompt.\(index)")
            }
        }
    }

    @ViewBuilder
    private func suggestedPromptButton(_ prompt: String) -> some View {
        if usesWorkspaceDesign {
            Button {
                Task { await viewModel.sendSuggestedPrompt(prompt) }
            } label: {
                HStack(spacing: Constants.Conversation.Design.SuggestedPrompt.contentSpacing) {
                    Text(LocalizedStringKey(prompt))
                        .interFont(Constants.Typography.bodyS)
                        .tracking(Constants.Conversation.Design.Typography.bodyTracking)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .allowsHitTesting(false)
                    Image(.arrowRight)
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(
                            width: Constants.Conversation.Design.iconSize,
                            height: Constants.Conversation.Design.iconSize
                        )
                        .accessibilityHidden(true)
                }
            }
            .buttonStyle(WorkspaceSuggestedPromptStyle())
        } else {
            legacySuggestedPromptButton(prompt)
        }
    }

    private func legacySuggestedPromptButton(_ prompt: String) -> some View {
        Button {
            Task { await viewModel.sendSuggestedPrompt(prompt) }
        } label: {
            HStack(spacing: Layout.suggestedPromptSpacing) {
                Image(.arrowRight)
                    .resizable()
                    .scaledToFit()
                    .frame(width: actionIconSide, height: actionIconSide)
                    .foregroundStyle(Theme.mutedForeground(for: transcriptColorScheme))
                    .accessibilityHidden(true)
                Text(LocalizedStringKey(prompt))
                    .interFont(Constants.Typography.bodyXS)
                    .foregroundStyle(Theme.foreground(for: transcriptColorScheme))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .allowsHitTesting(false)
            }
            .padding(.horizontal, Layout.suggestedPromptHorizontalPadding)
            .padding(.vertical, Layout.suggestedPromptVerticalPadding)
            .background(Theme.muted(for: transcriptColorScheme).opacity(Layout.suggestedPromptBackgroundOpacity))
            .clipShape(RoundedRectangle(cornerRadius: Layout.suggestedPromptCornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Layout.suggestedPromptCornerRadius)
                    .strokeBorder(
                        Theme.border(for: transcriptColorScheme).opacity(Layout.suggestedPromptBorderOpacity),
                        lineWidth: Layout.suggestedPromptBorderWidth
                    )
            )
        }
        .buttonStyle(IntentContentButtonStyle())
    }
    #endif
}

private struct WorkspaceSuggestedPromptStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.isEnabled) private var isEnabled

    private typealias Design = Constants.Conversation.Design
    private typealias Layout = Design.SuggestedPrompt

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Design.Palette.foreground(for: colorScheme))
            .padding(.horizontal, Layout.horizontalPadding)
            .padding(.vertical, Layout.verticalPadding)
            .frame(minHeight: Layout.minimumHeight)
            .background {
                RoundedRectangle(cornerRadius: Design.innerCornerRadius)
                    .fill(Design.Palette.surface(for: colorScheme))
                    .overlay {
                        RoundedRectangle(cornerRadius: Design.innerCornerRadius)
                            .fill(Design.Palette.foreground(for: colorScheme).opacity(
                                isEnabled && configuration.isPressed ? Layout.pressedOverlayOpacity : 0
                            ))
                    }
            }
            .overlay {
                RoundedRectangle(cornerRadius: Design.innerCornerRadius)
                    .strokeBorder(
                        Design.Palette.border(for: colorScheme, contrast: contrast),
                        lineWidth: Layout.borderWidth
                    )
            }
            .contentShape(.rect(cornerRadius: Design.innerCornerRadius))
            .opacity(isEnabled ? 1 : Layout.disabledOpacity)
    }
}
