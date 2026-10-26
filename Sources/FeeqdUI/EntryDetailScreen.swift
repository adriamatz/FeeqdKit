import FeeqdCore
import SwiftUI

/// One request: what was asked, where it stands, and the conversation under it.
struct EntryDetailScreen: View {
    let entryID: String
    /// The entry as the caller already had it (the roadmap reads its own pages), shown while —
    /// or instead of — the board's store knowing it.
    var seed: Entry? = nil
    @ObservedObject var store: BoardStore
    @StateObject private var comments: CommentsStore
    @State private var draft = ""
    @State private var replyingTo: Comment?
    @FocusState private var composerFocused: Bool

    @Environment(\.feeqdStrings) private var strings
    @Environment(\.feeqdTheme) private var theme

    init(entryID: String, store: BoardStore, seed: Entry? = nil) {
        self.entryID = entryID
        self.seed = seed
        self.store = store
        _comments = StateObject(wrappedValue: CommentsStore(client: store.client, boardID: store.boardID ?? "", entryID: entryID))
    }

    var body: some View {
        Group {
            if let entry = store.entry(id: entryID) ?? seed {
                detail(entry)
            } else {
                ProgressView()
            }
        }
        .feeqdInlineTitle()
        .task {
            // Opened from the roadmap: the board may not be loaded, and votes need the request
            // and which ones this device already backed.
            if let seed { store.open(seed) }
            if store.needsLoad { Task { await store.load() } }
            await comments.load(ownInReview: (store.entry(id: entryID) ?? seed)?.onlyYou == true)
        }
        .alert(
            strings(.errorTitle),
            isPresented: Binding(get: { comments.lastError != nil }, set: { if !$0 { comments.lastError = nil } }),
            presenting: comments.lastError
        ) { _ in
            Button(strings(.ok), role: .cancel) {}
        } message: { error in
            Text(feeqdMessage(for: error, strings: strings))
        }
    }

    private func detail(_ entry: Entry) -> some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    // Title and description switch language together, under one button.
                    Translatable(texts: [entry.title] + (entry.details.map { [$0] } ?? []), spacing: 10) { shown, translateButton in
                        Text(shown[0])
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(theme.textPrimary)
                        if shown.count > 1 {
                            Text(shown[1])
                                .font(.body)
                                .foregroundStyle(theme.textSecondary)
                        }
                        translateButton
                    }
                    HStack {
                        StatusBadge(status: store.status(for: entry.state), fallbackSlug: entry.state)
                        Spacer()
                        // Nobody else sees it yet, so nobody votes on it, the author included.
                        if !entry.onlyYou {
                            VoteButton(
                                count: entry.voteCount,
                                voted: store.votedIDs.contains(entry.id),
                                showsCount: store.config.behaviour.showVoteCount
                            ) {
                                Task { await store.toggleVote(entryID: entry.id) }
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            // In review, the thread is the author's and the team's; the public joins once it is published.
            if !entry.onlyYou || comments.isOpen {
                Section {
                    switch comments.phase {
                    case .loading:
                        ProgressView().frame(maxWidth: .infinity)
                    case let .failed(error):
                        ErrorStateView(error: error) { Task { await comments.load() } }
                    case .loaded where comments.comments.isEmpty:
                        Text(strings(.commentsEmpty))
                            .font(.subheadline)
                            .foregroundStyle(theme.textSecondary)
                    case .loaded:
                        ForEach(comments.threads) { thread in
                            CommentRow(comment: thread.root) {
                                replyingTo = thread.root
                                composerFocused = true
                            }
                            ForEach(thread.replies) { reply in
                                CommentRow(comment: reply, onReply: nil)
                                    .padding(.leading, 24)
                            }
                        }
                    }
                } header: {
                    Text(strings(.commentsTitle))
                } footer: {
                    if entry.onlyYou {
                        Text(strings(.entryOnlyYouHint))
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !entry.onlyYou || comments.isOpen { composer }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let replyingTo {
                HStack {
                    Text("\(strings(.commentReply)) · \(replyingTo.authorName ?? strings(.anonymousAuthor))")
                        .font(.caption)
                        .foregroundStyle(theme.textSecondary)
                    Spacer()
                    Button {
                        self.replyingTo = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(theme.textSecondary)
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(
                    replyingTo == nil ? strings(.commentPlaceholder) : strings(.commentReplyPlaceholder),
                    text: $draft,
                    axis: .vertical
                )
                .lineLimit(1...4)
                .focused($composerFocused)
                .textFieldStyle(.roundedBorder)
                Button {
                    Task {
                        if await comments.send(content: draft, parentID: replyingTo?.id) {
                            draft = ""
                            replyingTo = nil
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .buttonStyle(.borderless)
                .disabled(draft.feeqdTrimmed.isEmpty || comments.isSending)
                .accessibilityLabel(strings(.commentSend))
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }
}
