import SwiftUI

extension ConversationTranscriptView {
    static let eagerTailMessageLimit = 12

    @ViewBuilder
    func transcriptRows(proxy: ScrollViewProxy, dividerAnchorId: String?) -> some View {
        let generation = scrollState.initialScrollGeneration
        let ownershipRevision = scrollState.viewportOwnershipRevision
        let rows = viewModel.filteredMessages.map { message in
            (id: message.id, content: transcriptMessageRow(
                for: message,
                proxy: proxy,
                dividerAnchorId: dividerAnchorId,
                generation: generation,
                ownershipRevision: ownershipRevision
            ))
        }
        if viewModel.olderMessagesError != nil || !viewModel.hasOlderMessages {
            olderMessagesRow(proxy: proxy)
                .id("older-messages")
        }

        ForEach(rows.dropLast(Self.eagerTailMessageLimit), id: \.id) { @Sendable row in
            row.content
        }
        VStack(spacing: transcriptRowSpacing) {
            ForEach(rows.suffix(Self.eagerTailMessageLimit), id: \.id) { @Sendable row in
                row.content
            }
            transcriptEndRows(proxy: proxy)
        }
        .id("transcript-tail")
    }

    @ViewBuilder
    private func transcriptEndRows(proxy: ScrollViewProxy) -> some View {
        #if !os(visionOS)
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

        if !isDemoEndWithdrawn {
            Color.clear.frame(height: Layout.bottomAnchorHeight)
                .padding(.bottom, Layout.bottomAnchorPadding)
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
            Color.clear.frame(height: Layout.bottomAnchorHeight)
                .padding(.bottom, Layout.bottomAnchorPadding)
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
        return VStack(spacing: Layout.transcriptRowSpacing) {
            messageRow(for: message)
            if message.id == dividerAnchorId {
                entryDivider(dividerAnchorId: dividerAnchorId, generation: generation, ownershipRevision: ownershipRevision)
            }
        }
        .id(message.id)
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
        scrollState.retainViewportMessages(withIDs: viewModel.filteredMessageIDs)
        guard measurement.divider == viewModel.newMessagesDividerAnchorId,
              let geometry = scrollMomentumProxy.restingGeometry else { return }
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
        .transition(goToEndTransition)
        .animation(
            .easeInOut(duration: Constants.Conversation.Transcript.goToEndVisibilityAnimationDuration),
            value: userIsScrolledAway
        )
    }

    private var goToEndTransition: AnyTransition {
        switch ConversationTranscriptScrollPolicy.goToEndVisibilityTransition(reduceMotion: reduceMotion) {
        case .slideAndFade: .opacity.combined(with: .move(edge: .bottom))
        case .fade: .opacity
        }
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
            WorkspaceThinkingLabel(title: "Thinking…", showsDisclosure: false)
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
            Text("Thinking…")
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
                    .requiresLiveConnection("Reconnect to send")
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
                    Text(SuggestedPromptLinks.displayText(prompt))
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
                Text(SuggestedPromptLinks.displayText(prompt))
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
