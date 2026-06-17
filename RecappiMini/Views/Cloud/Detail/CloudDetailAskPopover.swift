import SwiftUI

/// Owns the conversation view model for the popover's lifetime so multi-turn
/// state survives `.popover` body re-evaluations. The detail view presents this
/// wrapper; it builds the `AskConversationViewModel` once via `@StateObject`.
struct CloudDetailAskPopoverContainer: View {
    @StateObject private var viewModel: AskConversationViewModel
    let onCitationTap: (AskCitation) -> Void

    init(
        recordingId: String,
        store: CloudLibraryStore,
        onCitationTap: @escaping (AskCitation) -> Void
    ) {
        _viewModel = StateObject(
            wrappedValue: AskConversationViewModel(recordingId: recordingId, store: store)
        )
        self.onCitationTap = onCitationTap
    }

    var body: some View {
        CloudDetailAskPopover(viewModel: viewModel, onCitationTap: onCitationTap)
    }
}

/// The "Ask this recording" conversation popover (the "B" Recording Assistant).
/// A persistent multi-turn chat: user bubbles on the right, assistant answers
/// with citation chips that jump into the transcript, plus follow-up
/// suggestions and a composer with a Web toggle.
struct CloudDetailAskPopover: View {
    @ObservedObject var viewModel: AskConversationViewModel
    /// Jump into the transcript at the cited segment.
    let onCitationTap: (AskCitation) -> Void

    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Palette.borderHairline)
            conversation
            Divider().overlay(Palette.borderHairline)
            composer
        }
        .frame(width: 380, height: 480)
        .background(Palette.surfaceCard)
        .onAppear {
            viewModel.loadIfNeeded()
            composerFocused = true
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DT.appAccent)
            Text("Ask this recording")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.dtLabel)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    // MARK: - Conversation

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if viewModel.phase == .loadingHistory {
                        loadingRow
                    } else if viewModel.messages.isEmpty {
                        if case .error(let reason) = viewModel.phase {
                            historyErrorRow(reason)
                        } else {
                            emptyState
                        }
                    } else {
                        ForEach(viewModel.messages) { message in
                            messageView(message)
                                .id(message.id)
                        }
                    }

                    if shouldShowFollowUps {
                        followUpSection
                            .id("ask-followups")
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
            }
            .onChange(of: viewModel.messages.count) { _, _ in
                scrollToBottom(proxy)
            }
            .onChange(of: viewModel.streamingText) { _, _ in
                scrollToBottom(proxy)
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.18)) {
            if shouldShowFollowUps {
                proxy.scrollTo("ask-followups", anchor: .bottom)
            } else if let last = viewModel.messages.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    private var loadingRow: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Loading conversation…")
                .font(.system(size: 12))
                .foregroundStyle(Color.dtLabelSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 24)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ask anything about this recording")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.dtLabel)
            Text("The assistant answers from the transcript and cites the moments it used.")
                .font(.system(size: 12))
                .foregroundStyle(Color.dtLabelSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 4)
    }

    private func historyErrorRow(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Couldn’t load this conversation")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.dtLabel)
            Text(reason)
                .font(.system(size: 11))
                .foregroundStyle(Color.red)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 4)
    }

    // MARK: - Message rendering

    @ViewBuilder
    private func messageView(_ message: AskConversationMessage) -> some View {
        switch message.role {
        case .user:
            userBubble(message)
        case .assistant:
            assistantBlock(message)
        }
    }

    private func userBubble(_ message: AskConversationMessage) -> some View {
        HStack {
            Spacer(minLength: 40)
            Text(message.content)
                .font(.system(size: 13))
                .foregroundStyle(Color.dtLabel)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.dtLabel.opacity(0.05))
                )
        }
    }

    @ViewBuilder
    private func assistantBlock(_ message: AskConversationMessage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("ANSWER")

            if message.content.isEmpty, message.status == .streaming {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Thinking…")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.dtLabelSecondary)
                }
            } else {
                answerBody(message.content)
            }

            if case .failed(let reason) = message.status {
                Text(reason)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // SOURCES citations removed per product decision — the bare
            // time-range chips weren't useful.
        }
    }

    /// Light markdown rendering for the answer: bullet / numbered list rows,
    /// paragraph spacing, and inline emphasis (bold/italic). Deliberately no
    /// tables / code blocks — keep it simple and cross-platform.
    @ViewBuilder
    private func answerBody(_ content: String) -> some View {
        let lines = content
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty {
                    Color.clear.frame(height: 2)
                } else if let bullet = bulletContent(trimmed) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•").font(.system(size: 13)).foregroundStyle(Color.dtLabelSecondary)
                        inlineText(bullet)
                    }
                } else if let numbered = numberedContent(trimmed) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(numbered.0).").font(.system(size: 13))
                            .foregroundStyle(Color.dtLabelSecondary).monospacedDigit()
                        inlineText(numbered.1)
                    }
                } else {
                    inlineText(trimmed)
                }
            }
        }
        .textSelection(.enabled)
    }

    private func inlineText(_ string: String) -> some View {
        let attributed = (try? AttributedString(
            markdown: string,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(string)
        return Text(attributed)
            .font(.system(size: 13))
            .foregroundStyle(Color.dtLabel)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func bulletContent(_ line: String) -> String? {
        for prefix in ["- ", "* ", "• "] where line.hasPrefix(prefix) {
            return String(line.dropFirst(prefix.count))
        }
        return nil
    }

    private func numberedContent(_ line: String) -> (Int, String)? {
        guard let range = line.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) else {
            return nil
        }
        let numberStr = line[range].prefix { $0.isNumber }
        guard let number = Int(numberStr) else { return nil }
        return (number, String(line[range.upperBound...]))
    }

    private func citationChip(_ citation: AskCitation) -> some View {
        Button {
            onCitationTap(citation)
        } label: {
            Text(citation.chipText)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(DT.appAccent)
                .lineLimit(1)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(
                    Capsule(style: .continuous)
                        .fill(DT.appAccent.opacity(0.10))
                )
        }
        .buttonStyle(.plain)
        .help(citation.snippet ?? citation.chipText)
    }

    // MARK: - Follow-ups

    private var shouldShowFollowUps: Bool {
        guard !viewModel.suggestions.isEmpty, !viewModel.isStreaming else { return false }
        // Show after at least one answer, or on the empty state to seed the chat.
        return viewModel.messages.last?.role == .assistant || viewModel.messages.isEmpty
    }

    private var followUpSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("ASK A FOLLOW-UP")
            FlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                ForEach(viewModel.suggestions, id: \.self) { suggestion in
                    Button {
                        viewModel.useSuggestion(suggestion)
                    } label: {
                        Text(suggestion)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.dtLabel)
                            .lineLimit(1)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(Palette.surfaceCardSubtle)
                            )
                            .overlay(
                                Capsule(style: .continuous)
                                    .strokeBorder(Palette.borderHairline, lineWidth: 0.6)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.top, 4)
    }

    // MARK: - Composer

    private var composer: some View {
        HStack(spacing: 8) {
            webToggle

            TextField("Ask a follow-up…", text: $viewModel.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(1...4)
                .focused($composerFocused)
                .onSubmit {
                    if viewModel.canSend { viewModel.send() }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Palette.surfaceCardSubtle)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Palette.borderHairline, lineWidth: 0.6)
                )

            sendButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var webToggle: some View {
        Button {
            viewModel.webSearch.toggle()
        } label: {
            Image(systemName: "globe")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(viewModel.webSearch ? DT.appAccent : Color.dtLabelTertiary)
                .frame(width: 30, height: 30)
                .background(
                    Circle()
                        .fill(viewModel.webSearch ? DT.appAccent.opacity(0.12) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .help(viewModel.webSearch ? "Web search on" : "Web search off")
    }

    private var sendButton: some View {
        Button {
            if viewModel.isStreaming {
                viewModel.cancelStreaming()
            } else if viewModel.canSend {
                viewModel.send()
            }
        } label: {
            ZStack {
                Circle()
                    .fill(sendButtonEnabled ? DT.appAccent : DT.appAccent.opacity(0.35))
                    .frame(width: 30, height: 30)
                if viewModel.isStreaming {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!sendButtonEnabled)
        .help(viewModel.isStreaming ? "Stop" : "Send")
    }

    private var sendButtonEnabled: Bool {
        viewModel.isStreaming || viewModel.canSend
    }

    // MARK: - Helpers

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(DT.appAccent)
    }
}
