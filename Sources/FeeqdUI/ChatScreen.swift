import FeeqdCore
import SwiftUI

/// The private chat with the team: bubbles, a composer, and a poll while it is on screen.
package struct ChatScreen: View {
    @StateObject private var store: ChatStore
    @State private var draft = ""
    @FocusState private var composerFocused: Bool

    @Environment(\.feeqdStrings) private var strings
    @Environment(\.feeqdTheme) private var theme

    package init(client: FeeqdClient, context: [String: String]? = nil) {
        _store = StateObject(wrappedValue: ChatStore(client: client, context: context))
    }

    package var body: some View {
        content
            // Behind the messages and the loading and error states, which otherwise show the
            // system's background, black in dark mode.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.background.ignoresSafeArea())
            .navigationTitle(strings(.chatTitle))
            .feeqdInlineTitle(theme)
            .task {
                await store.load()
                await store.poll()
            }
            .alert(
                strings(.errorTitle),
                isPresented: Binding(get: { store.lastError != nil }, set: { if !$0 { store.lastError = nil } }),
                presenting: store.lastError
            ) { _ in
                Button(strings(.ok), role: .cancel) {}
            } message: { error in
                Text(feeqdMessage(for: error, strings: strings))
            }
    }

    @ViewBuilder
    private var content: some View {
        switch store.phase {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .failed(error):
            // Never the inviting empty chat after a failed load: it would ask someone to write
            // into a conversation that may not be reachable.
            ErrorStateView(error: error) { Task { await store.load() } }
        case .loaded:
            messages.safeAreaInset(edge: .bottom) { composer }
        }
    }

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    if store.visibleMessages.isEmpty {
                        ChatEmptyState().padding(.top, 48)
                    }
                    ForEach(store.visibleMessages) { message in
                        ChatBubble(message: message).id(message.id)
                    }
                    if store.isClosed {
                        Text(strings(.chatClosed))
                            .font(.footnote)
                            .foregroundStyle(theme.textSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.vertical, 12)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .onAppear { scrollToBottom(proxy, animated: false) }
            .onChange(of: store.visibleMessages.last?.id) { _ in scrollToBottom(proxy, animated: true) }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let last = store.visibleMessages.last?.id else { return }
        if animated {
            withAnimation { proxy.scrollTo(last, anchor: .bottom) }
        } else {
            proxy.scrollTo(last, anchor: .bottom)
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(strings(.chatPlaceholder), text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .focused($composerFocused)
                .feeqdComposerField(theme)
            Button {
                let text = draft
                Task {
                    if await store.send(text) { draft = "" }
                }
            } label: {
                SendButtonLabel()
            }
            .buttonStyle(.plain)
            .disabled(draft.feeqdTrimmed.isEmpty || store.isSending)
            .accessibilityLabel(strings(.chatSend))
        }
        .feeqdComposerBar(theme)
    }
}

struct ChatBubble: View {
    let message: ChatMessage

    @Environment(\.feeqdStrings) private var strings
    @Environment(\.feeqdTheme) private var theme

    private var isMine: Bool { message.sender == .device }
    /// A review request reads in the user's language while it is the team's saved message.
    private var text: String { message.reviewAppStoreID == nil ? message.body : strings.reviewMessage(message.body) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            bubble
            if let appStoreID = message.reviewAppStoreID {
                ReviewCard(appStoreID: appStoreID).padding(.trailing, 48)
            }
        }
    }

    private var bubble: some View {
        HStack {
            if isMine { Spacer(minLength: 48) }
            VStack(alignment: isMine ? .trailing : .leading, spacing: 3) {
                if !isMine {
                    Text(message.senderName ?? strings(.chatTeam))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(theme.textSecondary)
                }
                Text(text)
                    .font(.body)
                    .foregroundStyle(isMine ? Color.white : theme.textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous)
                            // The surface colour is near the background by design (cards on a
                            // list); a bubble needs to read as a shape on its own.
                            .fill(isMine ? theme.primary : theme.textSecondary.opacity(0.14))
                    )
                    .textSelection(.enabled)
                if message.isPendingSend {
                    PendingSendNote(text: strings(.sendPending))
                        .font(.caption2)
                        .foregroundStyle(theme.textSecondary)
                } else if let date = message.createdAt {
                    Text(date, style: .time)
                        .font(.caption2)
                        .foregroundStyle(theme.textSecondary)
                }
            }
            if !isMine { Spacer(minLength: 48) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(isMine ? strings(.chatYou) : (message.senderName ?? strings(.chatTeam))): \(text)")
    }
}

private struct ChatEmptyState: View {
    @Environment(\.feeqdStrings) private var strings
    @Environment(\.feeqdTheme) private var theme

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.largeTitle)
                .foregroundStyle(theme.textSecondary)
            Text(strings(.chatEmptyTitle))
                .font(.headline)
            Text(strings(.chatEmptyMessage))
                .font(.subheadline)
                .foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 24)
    }
}

/// The chat on its own, for `Feeqd.ChatView()`: its own navigation and the dashboard's theme.
package struct StandaloneChatScreen: View {
    private let context: FeeqdContext
    private let ownsNavigation: Bool
    private let chatContext: [String: String]?
    @StateObject private var board: BoardStore

    package init(context: FeeqdContext, ownsNavigation: Bool = true, chatContext: [String: String]? = nil) {
        self.context = context
        self.ownsNavigation = ownsNavigation
        self.chatContext = chatContext
        _board = StateObject(wrappedValue: BoardStore(client: context.client, preferredBoardID: context.preferredBoardID))
    }

    private var strings: StringTable { context.strings.with(remote: board.config.strings) }
    private var theme: ResolvedTheme { ResolvedTheme(config: board.config, overrides: context.themeOverrides) }

    package var body: some View {
        Group {
            if ownsNavigation {
                NavigationStack { ChatScreen(client: context.client, context: chatContext) }
            } else {
                ChatScreen(client: context.client, context: chatContext)
            }
        }
        .tint(theme.primary)
        .feeqdFontDesign(theme.fontDesign)
        .environment(\.feeqdStrings, strings)
        .environment(\.feeqdTheme, theme)
        .task { await board.loadConfig() }
    }
}
