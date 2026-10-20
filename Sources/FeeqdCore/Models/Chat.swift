import Foundation

/// A private conversation between this device and the team, as `/sdk/chat/conversations`
/// lists it. The server keeps at most one open conversation per key and device.
package struct ChatConversation: Decodable, Equatable, Sendable, Identifiable {
    package enum Status: String, Sendable { case open, closed }

    package let id: String
    package let status: Status
    package let lastMessagePreview: String?
    package let lastMessageAt: Date?
    /// Team messages this device has not marked as read.
    package let unreadCount: Int
    package let createdAt: Date?

    package init(id: String, status: Status, lastMessagePreview: String?, lastMessageAt: Date?, unreadCount: Int, createdAt: Date?) {
        self.id = id
        self.status = status
        self.lastMessagePreview = lastMessagePreview
        self.lastMessageAt = lastMessageAt
        self.unreadCount = unreadCount
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id, status
        case lastMessagePreview = "last_message_preview"
        case lastMessageAt = "last_message_at"
        case unreadCount = "unread_count"
        case createdAt = "created_at"
    }

    /// Tolerant on purpose: a status the SDK does not know reads as closed, so a version already
    /// in the App Store never offers to write into something the server has moved on from.
    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        status = (try? c.decode(String.self, forKey: .status)).flatMap(Status.init(rawValue:)) ?? .closed
        lastMessagePreview = try? c.decode(String.self, forKey: .lastMessagePreview)
        lastMessageAt = (try? c.decode(String.self, forKey: .lastMessageAt)).flatMap(FeeqdDate.parse)
        unreadCount = (try? c.decode(Int.self, forKey: .unreadCount)) ?? 0
        createdAt = (try? c.decode(String.self, forKey: .createdAt)).flatMap(FeeqdDate.parse)
    }
}

package struct ChatConversationList: Decodable, Sendable {
    package let items: [ChatConversation]

    enum CodingKeys: String, CodingKey { case items }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = ((try? c.decode([Lossy<ChatConversation>].self, forKey: .items)) ?? []).compactMap(\.value)
    }
}

/// One message. Only `text` messages are shown: the server also writes `system` rows (the
/// conversation was opened) and `context` rows (a snapshot of the screen), which are for the
/// dashboard.
package struct ChatMessage: Decodable, Equatable, Sendable, Identifiable {
    package enum Sender: String, Sendable { case device, team }

    package let id: String
    package let sender: Sender
    package let senderName: String?
    package let kind: String
    package let body: String
    package let createdAt: Date?

    package var isText: Bool { kind == "text" && !body.isEmpty }

    package init(id: String, sender: Sender, senderName: String?, kind: String, body: String, createdAt: Date?) {
        self.id = id
        self.sender = sender
        self.senderName = senderName
        self.kind = kind
        self.body = body
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id, sender, kind, body
        case senderName = "sender_name"
        case createdAt = "created_at"
    }

    /// An unknown sender reads as the team: the one thing that must never happen is someone
    /// else's words drawn as the user's own.
    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        sender = (try? c.decode(String.self, forKey: .sender)).flatMap(Sender.init(rawValue:)) ?? .team
        senderName = try? c.decode(String.self, forKey: .senderName)
        kind = (try? c.decode(String.self, forKey: .kind)) ?? "text"
        body = (try? c.decode(String.self, forKey: .body)) ?? ""
        createdAt = (try? c.decode(String.self, forKey: .createdAt)).flatMap(FeeqdDate.parse)
    }
}

/// `GET /sdk/chat/conversations/{id}/messages`: the history (or what came after `since`) and
/// where the conversation stands.
package struct ChatMessageList: Decodable, Sendable {
    package let items: [ChatMessage]
    package let status: ChatConversation.Status

    enum CodingKeys: String, CodingKey { case items, status }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = ((try? c.decode([Lossy<ChatMessage>].self, forKey: .items)) ?? []).compactMap(\.value)
        status = (try? c.decode(String.self, forKey: .status)).flatMap(ChatConversation.Status.init(rawValue:)) ?? .closed
    }
}

/// `POST /sdk/chat/conversations`: `201` for a new conversation, `200` with the open one when
/// the device already has it.
package struct StartedConversation: Decodable, Sendable {
    package let id: String
    package let firstMessageID: String?

    enum CodingKeys: String, CodingKey {
        case id
        case firstMessageID = "first_message_id"
    }
}
