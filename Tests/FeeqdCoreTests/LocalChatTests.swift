import FeeqdCore
import XCTest

/// The chat against a real Feeqd stack: the device writes, the team answers, the device sees it.
///
/// Skipped unless `FEEQD_LOCAL_KEY` is set to a key with the `chat` scope, on a team with
/// `conversations` quota. `FEEQD_LOCAL_TEAM_TOKEN` (a dashboard access token for that team)
/// adds the team's side; without it only the device's side runs. Hosts as in `LocalStackTests`.
@MainActor
final class LocalChatTests: XCTestCase {
    private var client: FeeqdClient!
    private var gathererURL: URL!

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        guard let key = env["FEEQD_LOCAL_KEY"] else {
            throw XCTSkip("Set FEEQD_LOCAL_KEY to run the chat against a local stack")
        }
        gathererURL = URL(string: env["FEEQD_GATHERER_URL"] ?? "http://localhost:8092")!
        client = FeeqdClient(
            configuration: ClientConfiguration(
                apiKey: key,
                readerURL: URL(string: env["FEEQD_READER_URL"] ?? "http://localhost:8093")!,
                gathererURL: gathererURL,
                appVersion: "9.9.9"
            ),
            // A fresh device every run: each one gets its own conversation.
            identity: DeviceIdentity(store: InMemorySecretStore())
        )
    }

    func testTheWholeConversation() async throws {
        let before = await ChatStatus.check(client)
        XCTAssertEqual(before, ChatStatus(available: true, hasUnread: false), "a key with chat, nothing written yet")

        let store = ChatStore(client: client)
        await store.load()
        XCTAssertEqual(store.phase, .loaded)
        XCTAssertNil(store.conversation, "a new device has no conversation")

        let opened = await store.send("The export crashes on iPad")
        XCTAssertTrue(opened, "\(String(describing: store.lastError))")
        let conversationID = try XCTUnwrap(store.conversation?.id)
        XCTAssertEqual(store.visibleMessages.map(\.body), ["The export crashes on iPad"])

        let followUp = await store.send("It happens with PDFs")
        XCTAssertTrue(followUp, "\(String(describing: store.lastError))")
        XCTAssertEqual(store.visibleMessages.count, 2)

        let conversations = try await client.chatConversations()
        XCTAssertEqual(conversations.first?.id, conversationID)
        XCTAssertEqual(conversations.first?.status, .open)

        guard let teamToken = ProcessInfo.processInfo.environment["FEEQD_LOCAL_TEAM_TOKEN"] else { return }

        try await teamReply(conversationID: conversationID, body: "Thanks — fixed in the next build", token: teamToken)
        let unread = await ChatStatus.check(client)
        XCTAssertEqual(unread, ChatStatus(available: true, hasUnread: true), "the team's reply shows as unread")

        await store.refresh()
        let reply = try XCTUnwrap(store.visibleMessages.last)
        XCTAssertEqual(reply.sender, .team)
        XCTAssertEqual(reply.body, "Thanks — fixed in the next build")
        let read = await ChatStatus.check(client)
        XCTAssertEqual(read, ChatStatus(available: true, hasUnread: false), "refreshing on screen marks it read")

        try await teamClose(conversationID: conversationID, token: teamToken)
        await store.refresh()
        XCTAssertTrue(store.isClosed)
        let reopened = await store.send("One more thing")
        XCTAssertTrue(reopened, "\(String(describing: store.lastError))")
        XCTAssertNotEqual(store.conversation?.id, conversationID, "writing after a close opens a new conversation")
    }

    // MARK: The team's side, as the dashboard calls it

    private func teamReply(conversationID: String, body: String, token: String) async throws {
        try await teamPost("/team/chat/conversations/\(conversationID)/messages", ["body": body], token: token, expect: 201)
    }

    private func teamClose(conversationID: String, token: String) async throws {
        try await teamPost("/team/chat/conversations/\(conversationID)/close", [:], token: token, expect: 204)
    }

    private func teamPost(_ path: String, _ body: [String: String], token: String, expect: Int) async throws {
        var request = URLRequest(url: gathererURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, expect, String(decoding: data, as: UTF8.self))
    }
}
