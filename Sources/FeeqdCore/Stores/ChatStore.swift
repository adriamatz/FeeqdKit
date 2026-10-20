import Combine
import Foundation

/// The device's side of the private chat with the team.
///
/// Shows one conversation: the open one, or else the most recent. Writing after a conversation
/// was closed reopens it, so the history stays in one thread; a backend that cannot reopen, or a
/// device that already has another conversation open, starts or continues that one instead.
/// There is no push yet, so the screen polls while it is visible.
@MainActor
package final class ChatStore: ObservableObject {
    package enum Phase: Equatable {
        case loading, loaded
        case failed(FeeqdError)
    }

    /// The server counts bytes, not characters: `len()` of the Go string.
    package static let maxMessageBytes = 4000

    @Published package private(set) var phase: Phase = .loading
    @Published package private(set) var conversation: ChatConversation?
    @Published package private(set) var messages: [ChatMessage] = []
    @Published package private(set) var isSending = false
    @Published package var lastError: FeeqdError?

    package let client: FeeqdClient
    private var lastMarkedRead: String?

    package init(client: FeeqdClient) {
        self.client = client
    }

    /// What the screen draws: only what people wrote.
    package var visibleMessages: [ChatMessage] { messages.filter(\.isText) }

    package var isClosed: Bool { conversation?.status == .closed }

    package func load() async {
        do {
            let conversations = try await client.chatConversations()
            // Newest first from the server; an open one always wins.
            let current = conversations.first { $0.status == .open } ?? conversations.first
            if let current {
                let history = try await client.chatMessages(conversationID: current.id)
                conversation = current.with(status: history.status)
                messages = history.items
            } else {
                conversation = nil
                messages = []
            }
            phase = .loaded
            await markReadIfNeeded()
        } catch {
            if FeeqdError.isCancellation(error) { return }
            let wrapped = FeeqdError.wrap(error)
            if phase == .loaded {
                lastError = wrapped
            } else {
                phase = .failed(wrapped)
            }
        }
    }

    /// Fetches what arrived since the last message. Quiet on failure: the next tick retries,
    /// and an alert every five seconds on a bad connection would be worse than a stale screen.
    package func refresh() async {
        guard phase == .loaded, let conversation else { return }
        do {
            let update = try await client.chatMessages(conversationID: conversation.id, sinceID: messages.last?.id)
            let known = Set(messages.map(\.id))
            messages.append(contentsOf: update.items.filter { !known.contains($0.id) })
            if update.status != conversation.status {
                self.conversation = conversation.with(status: update.status)
            }
            await markReadIfNeeded()
        } catch {}
    }

    /// Polls every `interval` until the task that calls it is cancelled (the view went away).
    package func poll(every interval: TimeInterval = 5) async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await refresh()
        }
    }

    @discardableResult
    package func send(_ text: String) async -> Bool {
        let body = text.feeqdTrimmed
        guard !body.isEmpty, !isSending else { return false }
        guard body.utf8.count <= Self.maxMessageBytes else {
            lastError = .server(status: 422, code: "message_too_long", message: nil)
            return false
        }
        isSending = true
        defer { isSending = false }
        do {
            if let conversation {
                do {
                    try await append(body, to: conversation.id)
                    // Writing to a closed conversation reopened it.
                    if conversation.status != .open { self.conversation = conversation.with(status: .open) }
                } catch FeeqdError.conversationClosed {
                    // A backend that does not reopen, or another conversation already open for
                    // this device: start one, which hands back the open one if there is.
                    try await start(with: body)
                }
            } else {
                try await start(with: body)
            }
            return true
        } catch {
            lastError = FeeqdError.wrap(error)
            return false
        }
    }

    private func append(_ body: String, to conversationID: String) async throws {
        let message = try await client.sendChatMessage(conversationID: conversationID, body: body)
        if !messages.contains(where: { $0.id == message.id }) { messages.append(message) }
    }

    private func start(with body: String) async throws {
        let started = try await client.startConversation(message: body)
        // `200` with an open conversation this screen did not know about: the message was not
        // stored with it, so it goes in as a normal message.
        if started.firstMessageID == nil {
            _ = try await client.sendChatMessage(conversationID: started.id, body: body)
        }
        // The message is stored by now. If reading the thread back fails, that is not a failed
        // send: reporting one would have the user send it twice. The next poll fills the thread.
        let history = try? await client.chatMessages(conversationID: started.id)
        conversation = ChatConversation(
            id: started.id, status: history?.status ?? .open, lastMessagePreview: body, lastMessageAt: Date(), unreadCount: 0,
            createdAt: Date()
        )
        if let history { messages = history.items }
        phase = .loaded
    }

    /// Marks up to the newest message, once per new message.
    private func markReadIfNeeded() async {
        guard let conversation, let last = messages.last?.id, last != lastMarkedRead else { return }
        guard messages.contains(where: { $0.sender == .team && $0.isText }) || conversation.unreadCount > 0 else { return }
        do {
            try await client.markChatRead(conversationID: conversation.id, lastReadID: last)
            lastMarkedRead = last
        } catch {}
    }
}

/// Whether the chat can be offered, and whether the team wrote something unread.
package struct ChatStatus: Equatable, Sendable {
    package var available: Bool
    package var hasUnread: Bool

    package init(available: Bool, hasUnread: Bool) {
        self.available = available
        self.hasUnread = hasUnread
    }

    package static let unavailable = ChatStatus(available: false, hasUnread: false)

    /// Fails closed: a key without the chat scope, a plan without it, or no network all mean
    /// no chat button. Offering a chat that cannot deliver is worse than not offering one.
    ///
    /// `acceptingNew` is the config's `accepting_conversations`: with the team's quota used up
    /// the chat is offered only to someone who already has a conversation open.
    package static func check(_ client: FeeqdClient, acceptingNew: Bool = true) async -> ChatStatus {
        guard let conversations = try? await client.chatConversations() else { return .unavailable }
        guard acceptingNew || conversations.contains(where: { $0.status == .open }) else { return .unavailable }
        return ChatStatus(available: true, hasUnread: conversations.contains { $0.unreadCount > 0 })
    }
}

extension ChatConversation {
    func with(status: Status) -> ChatConversation {
        ChatConversation(
            id: id, status: status, lastMessagePreview: lastMessagePreview, lastMessageAt: lastMessageAt,
            unreadCount: unreadCount, createdAt: createdAt
        )
    }
}
