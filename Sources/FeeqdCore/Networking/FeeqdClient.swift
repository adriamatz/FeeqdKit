import Foundation
import os

package enum FeeqdCoreVersion {
    package static let current = "0.3.0"
}

package struct ClientConfiguration: Sendable {
    package var apiKey: String
    /// go-reader: config and every public read.
    package var readerURL: URL
    /// go-gatherer: votes, comments, submissions.
    package var gathererURL: URL
    package var sdkVersion: String
    package var appVersion: String?

    package init(
        apiKey: String,
        readerURL: URL,
        gathererURL: URL,
        sdkVersion: String = FeeqdCoreVersion.current,
        appVersion: String? = nil
    ) {
        self.apiKey = apiKey
        self.readerURL = readerURL
        self.gathererURL = gathererURL
        self.sdkVersion = sdkVersion
        self.appVersion = appVersion
    }
}

package protocol DeviceIdentityProviding: Sendable {
    func deviceID() async throws -> String
    /// Forgets the device id and takes a new one: the next person on this install starts clean.
    func reset() async
}

/// Every request the SDK makes, and nothing else.
///
/// An actor so the identity token, the claimed identity and the config's ETag are read and
/// written from one place. Routes and bodies are the ones the local stack answers today
/// (captured in `Tests/FeeqdCoreTests/Fixtures`), not the ones a spec promised.
package actor FeeqdClient {
    private enum Credential { case anonymous, key, keyAndDevice }
    private enum Service { case reader, gatherer }

    private let configuration: ClientConfiguration
    private let session: URLSession
    private let identity: DeviceIdentityProviding
    private let decoder = JSONDecoder.feeqd
    private var identityToken: String?
    private var claimedID: String?
    private var claimedName: String?
    private var claimedEmail: String?
    /// What the user pays: the app's own figure wins over what StoreKit reports.
    private var manualPayment: PaymentSummary?
    private var storePayment: PaymentSummary?
    /// Bumped by `reset()`. A StoreKit read that started before it carries the old number and
    /// is dropped, so it can't put the previous user's payment back.
    package private(set) var paymentGeneration = 0
    private var cachedConfig: (etag: String, config: SDKConfig)?
    private nonisolated let lastConfigLock = OSAllocatedUnfairLock<SDKConfig?>(initialState: nil)

    /// The last config this client read, without waiting on the actor: a screen opens with it at
    /// once and revalidates (`configure` already read it at launch).
    package nonisolated var lastConfig: SDKConfig? { lastConfigLock.withLock { $0 } }
    /// Set by a `429 quota_exceeded`: the plan is full even if the config cached here still
    /// says otherwise. A fresh config from the server (a `200`) is the truth again.
    private var entriesFull = false
    private var conversationsFull = false

    /// A `429 rate_limited` asking for no more than this is waited out and sent once more;
    /// a longer wait is the user's to decide.
    package static let maxAutoRetryDelay: TimeInterval = 10

    package init(configuration: ClientConfiguration, session: URLSession = .shared, identity: DeviceIdentityProviding) {
        self.configuration = configuration
        self.session = session
        self.identity = identity
    }

    package func setIdentityToken(_ token: String?) {
        identityToken = token
    }

    /// Unsigned. Anyone holding the key can send any value, so the dashboard treats it as a hint.
    package func setClaimedIdentity(id: String?, name: String?, email: String? = nil) {
        claimedID = id
        claimedName = name
        claimedEmail = email
    }

    /// Signing out: nothing of the previous user rides on the next request, and the device id is
    /// new, so their chat and their own requests are not shown to whoever signs in next.
    package func reset() async {
        identityToken = nil
        claimedID = nil
        claimedName = nil
        claimedEmail = nil
        manualPayment = nil
        storePayment = nil
        paymentGeneration += 1
        await identity.reset()
    }

    package func setManualPayment(_ payment: PaymentSummary?) {
        manualPayment = payment
    }

    /// `generation` is `paymentGeneration` as it was when the StoreKit read began.
    package func setStorePayment(_ payment: PaymentSummary?, generation: Int) {
        guard generation == paymentGeneration else { return }
        storePayment = payment
    }

    package var payment: PaymentSummary? { manualPayment ?? storePayment }

    // MARK: Reads

    /// `GET /sdk/config`, revalidated with the ETag of the previous answer (`304` → cached copy).
    package func config() async throws -> SDKConfig {
        var headers: [String: String] = [:]
        if let cachedConfig { headers["If-None-Match"] = cachedConfig.etag }
        let (data, response) = try await send("GET", .reader, "/sdk/config", credential: .key, headers: headers, acceptNotModified: true)
        if response.statusCode == 304, let cachedConfig {
            let config = applyingLocalQuota(cachedConfig.config)
            lastConfigLock.withLock { $0 = config }
            return config
        }
        let config = try decode(SDKConfig.self, data)
        if let etag = response.value(forHTTPHeaderField: "ETag") {
            cachedConfig = (etag, config)
        }
        entriesFull = false
        conversationsFull = false
        lastConfigLock.withLock { $0 = config }
        return config
    }

    private func applyingLocalQuota(_ config: SDKConfig) -> SDKConfig {
        var config = config
        if entriesFull { config.acceptingEntries = false }
        if conversationsFull { config.acceptingConversations = false }
        return config
    }

    package func entries(
        boardID: String,
        page: Int,
        pageSize: Int,
        sort: SDKConfig.SortOrder,
        query: String? = nil
    ) async throws -> Page<Entry> {
        var items = [
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "page_size", value: String(pageSize)),
            URLQueryItem(name: "sort_by", value: sort.rawValue),
        ]
        if let query, !query.isEmpty { items.append(URLQueryItem(name: "q", value: query)) }
        let (data, _) = try await send("GET", .reader, "/public/feedback/\(boardID)", query: items)
        return try decode(Page<Entry>.self, data)
    }

    /// `GET /public/roadmap/{id}`: a team roadmap's entries. Only public roadmaps and public
    /// entries come back; anything else reads as an empty roadmap.
    package func roadmapEntries(roadmapID: String) async throws -> [Entry] {
        let (data, _) = try await send("GET", .reader, "/public/roadmap/\(roadmapID)")
        return try Self.decodeRoadmapEntries(data)
    }

    package static func decodeRoadmapEntries(_ data: Data) throws -> [Entry] {
        struct Item: Decodable, Sendable { let entry: Entry }
        struct Detail: Decodable, Sendable { let items: [Lossy<Item>]? }
        return (try JSONDecoder.feeqd.decode(Detail.self, from: data).items ?? []).compactMap(\.value?.entry)
    }

    package func entry(boardID: String, entryID: String) async throws -> Entry {
        let (data, _) = try await send("GET", .reader, "/public/feedback/\(boardID)/entries/\(entryID)")
        return try decode(Entry.self, data)
    }

    package func comments(boardID: String, entryID: String, page: Int, pageSize: Int) async throws -> Page<Comment> {
        let query = [URLQueryItem(name: "page", value: String(page)), URLQueryItem(name: "page_size", value: String(pageSize))]
        let (data, _) = try await send("GET", .reader, "/public/feedback/\(boardID)/entries/\(entryID)/comments", query: query)
        return try decode(Page<Comment>.self, data)
    }

    /// The comments on a request this device sent, read as its author: the team's replies while
    /// the request is still in review, when the public route answers 404 for it. A backend from
    /// before this route answers a bare 404 too (`isMissingRoute`).
    package func myComments(boardID: String, entryID: String, page: Int, pageSize: Int) async throws -> Page<Comment> {
        let query = [URLQueryItem(name: "page", value: String(page)), URLQueryItem(name: "page_size", value: String(pageSize))]
        let (data, _) = try await send(
            "GET", .reader, "/sdk/boards/\(boardID)/mine/\(entryID)/comments", query: query, credential: .keyAndDevice
        )
        return try decode(Page<Comment>.self, data)
    }

    package func similar(boardID: String, title: String) async throws -> [SimilarEntry] {
        let (data, _) = try await send(
            "GET", .reader, "/public/feedback/\(boardID)/similar", query: [URLQueryItem(name: "title", value: title)]
        )
        return try decode(SimilarResponse.self, data).items
    }

    /// Also how the dashboard learns the app launched: any authenticated SDK call registers
    /// the device, and the onboarding watches the workspace's device count. It carries the app
    /// and SDK versions (not the device's diagnostics), so the registration has a version.
    package func myVotes(boardID: String) async throws -> Set<String> {
        var headers: [String: String] = [:]
        if let launch = DeviceInfo.launchHeaderValue(sdkVersion: configuration.sdkVersion, appVersion: configuration.appVersion) {
            headers["X-Feeqd-Device-Info"] = launch
        }
        let (data, _) = try await send("GET", .gatherer, "/sdk/boards/\(boardID)/my-votes", credential: .keyAndDevice, headers: headers)
        return Set(try decode(MyVotes.self, data).entryIDs)
    }

    /// Sent once by `configure`: the app launched. Without it the dashboard would only see the
    /// app once someone opens a Feeqd screen, and "run the app once" would not connect it. The
    /// config it reads is the one the first screen needs anyway (cached, then a `304`). Quiet on
    /// failure: the next screen load registers the device just the same.
    package func announceLaunch(preferredBoardID: String?) async {
        guard let config = try? await config(),
              let board = preferredBoardID ?? config.boardID ?? config.boards.first?.id else { return }
        _ = try? await myVotes(boardID: board)
    }

    // MARK: Writes

    package func vote(boardID: String, entryID: String) async throws -> VoteResult {
        let (data, _) = try await send(
            "POST", .gatherer, "/sdk/boards/\(boardID)/entries/\(entryID)/vote",
            body: Data("{}".utf8), credential: .keyAndDevice, isUserAction: true
        )
        return try decode(VoteResult.self, data)
    }

    package func retractVote(boardID: String, entryID: String) async throws -> VoteResult {
        let (data, _) = try await send(
            "DELETE", .gatherer, "/sdk/boards/\(boardID)/entries/\(entryID)/vote", credential: .keyAndDevice, isUserAction: true
        )
        return try decode(VoteResult.self, data)
    }

    package func comment(boardID: String, entryID: String, content: String, parentID: String? = nil) async throws -> CreatedComment {
        var body: [String: Any] = ["content": content]
        if let parentID { body["parent_id"] = parentID }
        let (data, _) = try await send(
            "POST", .gatherer, "/sdk/boards/\(boardID)/entries/\(entryID)/comments",
            body: try JSONSerialization.data(withJSONObject: body), credential: .keyAndDevice, isUserAction: true
        )
        return try decode(CreatedComment.self, data)
    }

    /// What this device submitted to the board, newest first, including requests nobody else sees
    /// yet (`onlyYou`). A backend without the route answers 404: then there is nothing to add.
    package func mine(boardID: String) async throws -> [Entry] {
        struct Response: Decodable { let items: [Entry] }
        let (data, _) = try await send("GET", .reader, "/sdk/boards/\(boardID)/mine", credential: .keyAndDevice)
        return try decoder.decode(Response.self, from: data).items
    }

    /// Sends a request through the SDK's own route: the key authorises it, and a signed-in
    /// user is its author. A backend from before that route answers a bare 404; the request then
    /// goes the way it always did, through the public route, as an anonymous one. Any other 404
    /// (`board_not_found`: a board outside the key) is the answer, and is thrown: retrying it on
    /// the public route would get round what the key allows.
    package func submit(boardID: String, title: String, description: String) async throws -> SubmitReceipt {
        do {
            let body = ["title": title, "description": description]
            let (data, _) = try await send(
                "POST", .gatherer, "/sdk/boards/\(boardID)/entries",
                body: try JSONSerialization.data(withJSONObject: body), credential: .keyAndDevice, isUserAction: true
            )
            return try decode(SubmitReceipt.self, data)
        } catch FeeqdError.quotaExceeded {
            entriesFull = true
            throw FeeqdError.quotaExceeded
        } catch let error as FeeqdError where error.isMissingRoute {
            let body: [String: Any] = [
                "type": "comment",
                "content": ["title": title, "description": description],
                "source": "api",
                "source_id": "feeqdkit-ios",
            ]
            let (data, _) = try await send(
                "POST", .gatherer, "/public/comment/\(boardID)",
                body: try JSONSerialization.data(withJSONObject: body), credential: .keyAndDevice, isUserAction: true
            )
            return try decode(SubmitReceipt.self, data)
        }
    }

    // MARK: Chat

    /// Reads go to go-reader, writes to go-gatherer, like everything else. Every chat call
    /// needs a key with the `chat` scope and the device id: the conversations are this
    /// device's, and the server scopes them to (key, device) on its side.
    package func chatConversations() async throws -> [ChatConversation] {
        let (data, _) = try await send("GET", .reader, "/sdk/chat/conversations", credential: .keyAndDevice)
        return try decode(ChatConversationList.self, data).items
    }

    /// The whole history, or only what came after `sinceID` (a message id).
    package func chatMessages(conversationID: String, sinceID: String? = nil) async throws -> ChatMessageList {
        var query: [URLQueryItem] = []
        if let sinceID { query.append(URLQueryItem(name: "since", value: sinceID)) }
        let (data, _) = try await send(
            "GET", .reader, "/sdk/chat/conversations/\(conversationID)/messages", query: query, credential: .keyAndDevice
        )
        return try decode(ChatMessageList.self, data)
    }

    /// Opens a conversation with its first message. If the device already has one open, the
    /// server hands that one back untouched — and the message is not added to it, so the
    /// caller sends it separately (`firstMessageID` is `nil` in that case).
    package func startConversation(message: String) async throws -> StartedConversation {
        do {
            let (data, _) = try await send(
                "POST", .gatherer, "/sdk/chat/conversations",
                body: try JSONSerialization.data(withJSONObject: ["message": message]), credential: .keyAndDevice, isUserAction: true
            )
            return try decode(StartedConversation.self, data)
        } catch FeeqdError.quotaExceeded {
            conversationsFull = true
            throw FeeqdError.quotaExceeded
        }
    }

    package func sendChatMessage(conversationID: String, body: String) async throws -> ChatMessage {
        let (data, _) = try await send(
            "POST", .gatherer, "/sdk/chat/conversations/\(conversationID)/messages",
            body: try JSONSerialization.data(withJSONObject: ["body": body]), credential: .keyAndDevice, isUserAction: true
        )
        return try decode(ChatMessage.self, data)
    }

    package func closeConversation(conversationID: String) async throws {
        _ = try await send(
            "POST", .gatherer, "/sdk/chat/conversations/\(conversationID)/close", body: Data("{}".utf8), credential: .keyAndDevice
        )
    }

    package func markChatRead(conversationID: String, lastReadID: String) async throws {
        _ = try await send(
            "POST", .gatherer, "/sdk/chat/conversations/\(conversationID)/read",
            body: try JSONSerialization.data(withJSONObject: ["last_read_id": lastReadID]), credential: .keyAndDevice
        )
    }

    // MARK: Plumbing

    private func send(
        _ method: String,
        _ service: Service,
        _ path: String,
        query: [URLQueryItem] = [],
        body: Data? = nil,
        credential: Credential = .anonymous,
        isUserAction: Bool = false,
        headers: [String: String] = [:],
        acceptNotModified: Bool = false,
        isRetry: Bool = false
    ) async throws -> (Data, HTTPURLResponse) {
        let base = service == .reader ? configuration.readerURL : configuration.gathererURL
        guard var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw FeeqdError.transport("Invalid URL for \(path)")
        }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw FeeqdError.transport("Invalid URL for \(path)") }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if credential != .anonymous {
            request.setValue(configuration.apiKey, forHTTPHeaderField: "X-Feeqd-Key")
        }
        if credential == .keyAndDevice {
            let deviceID: String
            do {
                deviceID = try await identity.deviceID()
            } catch {
                throw FeeqdError.transport("The device id cannot be read until the device is unlocked")
            }
            request.setValue(deviceID, forHTTPHeaderField: "X-Feeqd-Device-Id")
            // `/public/comment`, the fallback for a backend without the SDK's submit route, reads
            // this header as a web widget's token and refuses ours: there it goes without.
            if let identityToken, !path.hasPrefix("/public/") {
                request.setValue(identityToken, forHTTPHeaderField: "x-identity-token")
            }
            // Who the user is and what they pay ride only on what they do (a vote, a comment, a
            // request, a message), which is where the server stores them. Never on a read: a chat
            // open on screen polls every few seconds.
            if method != "GET" {
                if let claimedID { request.setValue(claimedID, forHTTPHeaderField: "X-Feeqd-Claimed-Id") }
                if let claimedName { request.setValue(claimedName, forHTTPHeaderField: "X-Feeqd-Claimed-Name") }
                if let claimedEmail { request.setValue(claimedEmail, forHTTPHeaderField: "X-Feeqd-Claimed-Email") }
                if let payment { request.setValue(payment.headerValue, forHTTPHeaderField: "X-Feeqd-User-Payment") }
            }
        }
        // Diagnostics ride only on something the user did, never on a background read: that
        // keeps them in Apple's Diagnostics category and out of the host app's privacy label.
        if isUserAction, let info = DeviceInfo.headerValue(sdkVersion: configuration.sdkVersion, appVersion: configuration.appVersion) {
            request.setValue(info, forHTTPHeaderField: "X-Feeqd-Device-Info")
        }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            // A cancelled request is not a failed one: it stays recognisable to the stores.
            if FeeqdError.isCancellation(error) { throw CancellationError() }
            throw FeeqdError.wrap(error)
        }
        guard let http = response as? HTTPURLResponse else { throw FeeqdError.transport("No HTTP response") }
        if (200..<300).contains(http.statusCode) || (acceptNotModified && http.statusCode == 304) {
            return (data, http)
        }
        let error = FeeqdError.from(status: http.statusCode, data: data, retryAfter: http.value(forHTTPHeaderField: "Retry-After"))
        // A 429 was never processed, so sending it again cannot do anything twice.
        if !isRetry, case let .rateLimited(after?) = error, after <= Self.maxAutoRetryDelay {
            try await Task.sleep(nanoseconds: UInt64(max(after, 0) * 1_000_000_000))
            return try await send(
                method, service, path, query: query, body: body, credential: credential, isUserAction: isUserAction,
                headers: headers, acceptNotModified: acceptNotModified, isRetry: true
            )
        }
        throw error
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw FeeqdError.decoding(String(describing: error))
        }
    }
}
