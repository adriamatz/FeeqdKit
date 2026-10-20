import FeeqdCore
import XCTest

final class ClientTests: XCTestCase {
    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    func testConfigSendsTheKeyAndRevalidatesWithItsETag() async throws {
        let body = try Fixture.data("sdk_config")
        StubURLProtocol.responder = { request in
            if request.value(forHTTPHeaderField: "If-None-Match") == "W/\"v1\"" { return .init(status: 304) }
            return .json(200, body, headers: ["ETag": "W/\"v1\""])
        }
        let client = FeeqdClient.stubbed()
        let first = try await client.config()
        let second = try await client.config()

        XCTAssertEqual(first, second, "a 304 hands back the cached config")
        XCTAssertEqual(StubURLProtocol.requests.count, 2)
        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "http://reader.test/sdk/config")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Feeqd-Key"), "feeqd_pk_test")
        XCTAssertNil(request.value(forHTTPHeaderField: "X-Feeqd-Device-Id"), "config is per key, not per device")
    }

    func testPublicReadsCarryNoCredentialAndTheRightQuery() async throws {
        let body = try Fixture.data("entries_page")
        StubURLProtocol.responder = { _ in .json(200, body) }
        _ = try await FeeqdClient.stubbed().entries(boardID: "B", page: 2, pageSize: 20, sort: .recent, query: "kindle")

        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        let components = try XCTUnwrap(URLComponents(url: request.url!, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.path, "/public/feedback/B")
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query, ["page": "2", "page_size": "20", "sort_by": "recent", "q": "kindle"])
        XCTAssertNil(request.value(forHTTPHeaderField: "X-Feeqd-Key"), "the public list is shared and cacheable")
    }

    /// `my-votes` is the launch request: device id and versions, but no device diagnostics.
    func testMyVotesSendsTheDeviceAndVersionsButNoDiagnostics() async throws {
        let body = try Fixture.data("my_votes")
        StubURLProtocol.responder = { _ in .json(200, body) }
        let votes = try await FeeqdClient.stubbed(deviceID: "dev_abc").myVotes(boardID: "B")

        XCTAssertEqual(votes, ["0003BNsEyoDrlLzjZ55HPXmoCv3"])
        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "http://gatherer.test/sdk/boards/B/my-votes")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Feeqd-Device-Id"), "dev_abc")
        let info = try XCTUnwrap(request.value(forHTTPHeaderField: "X-Feeqd-Device-Info"))
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(info.utf8)) as? [String: String])
        XCTAssertEqual(Set(fields.keys).subtracting(["app", "sdk"]), [], "no model, OS or locale on a launch")
    }

    func testVoteIsAUserActionAndCarriesDiagnostics() async throws {
        let body = try Fixture.data("vote_cast")
        StubURLProtocol.responder = { _ in .json(200, body) }
        _ = try await FeeqdClient.stubbed().vote(boardID: "B", entryID: "E")

        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/sdk/boards/B/entries/E/vote")
        let info = try XCTUnwrap(request.value(forHTTPHeaderField: "X-Feeqd-Device-Info"))
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: Data(info.utf8)) as? [String: String])
    }

    func testIdentityHeadersRideOnDeviceRequests() async throws {
        let body = try Fixture.data("comment_created")
        StubURLProtocol.responder = { _ in .json(201, body) }
        let client = FeeqdClient.stubbed()
        await client.setIdentityToken("jwt.token.here")
        await client.setClaimedIdentity(id: "user-42", name: "Marta")
        _ = try await client.comment(boardID: "B", entryID: "E", content: "Hi", parentID: "C1")

        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-identity-token"), "jwt.token.here")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Feeqd-Claimed-Id"), "user-42")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: String])
        XCTAssertEqual(json, ["content": "Hi", "parent_id": "C1"])
    }

    func testWhoTheUserIsNeverRidesOnARead() async throws {
        let votes = try Fixture.data("my_votes")
        StubURLProtocol.responder = { _ in .json(200, votes) }
        let client = FeeqdClient.stubbed()
        await client.setClaimedIdentity(id: "user-42", name: "Marta", email: "marta@example.com")
        await client.setManualPayment(PaymentSummary(period: .month, amount: 4.99, currency: "EUR", source: .manual))
        _ = try await client.myVotes(boardID: "B")

        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Feeqd-Device-Id"), "dev_test_device")
        for header in ["X-Feeqd-Claimed-Id", "X-Feeqd-Claimed-Name", "X-Feeqd-Claimed-Email", "X-Feeqd-User-Payment"] {
            XCTAssertNil(request.value(forHTTPHeaderField: header), "\(header) on a read")
        }
    }

    /// The SDK's own route: the key authorises it and the signed-in user is the author.
    func testSubmitGoesThroughTheSDKRouteWithTheIdentityToken() async throws {
        let accepted = try Fixture.data("submit_accepted")
        StubURLProtocol.responder = { _ in .json(202, accepted) }
        let client = FeeqdClient.stubbed()
        await client.setIdentityToken("jwt.token.here")
        let receipt = try await client.submit(boardID: "B", title: "Dark mode", description: "Please")

        XCTAssertEqual(receipt.status, "queued")
        XCTAssertEqual(StubURLProtocol.requests.count, 1)
        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "http://gatherer.test/sdk/boards/B/entries")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-identity-token"), "jwt.token.here")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Feeqd-Device-Id"), "dev_test_device")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: String])
        XCTAssertEqual(json, ["title": "Dark mode", "description": "Please"])
    }

    /// A board outside the key is a 404 too, but it is the answer: going round it through the
    /// public route would post where the key does not allow.
    func testSubmitToABoardOutsideTheKeyDoesNotFallBack() async throws {
        StubURLProtocol.responder = { _ in
            .json(404, Data(#"{"error": "board_not_found", "message": "Board not found"}"#.utf8))
        }
        let client = FeeqdClient.stubbed()
        do {
            _ = try await client.submit(boardID: "B", title: "Dark mode", description: "Please")
            XCTFail("expected board_not_found")
        } catch let error as FeeqdError {
            XCTAssertEqual(error, .notFound(code: "board_not_found"))
        }
        XCTAssertEqual(StubURLProtocol.requests.map { $0.url?.path }, ["/sdk/boards/B/entries"])
    }

    /// A backend from before that route answers 404: the request goes through the public one,
    /// in the body it accepts (without `source_id` it answers 400) and without the identity
    /// token, which that route takes for a web widget's and refuses.
    func testSubmitFallsBackToThePublicRouteOnAnOlderBackend() async throws {
        let accepted = try Fixture.data("submit_accepted")
        StubURLProtocol.responder = { request in
            request.url?.path.hasPrefix("/sdk/") == true
                ? .json(404, Data(#"{"error": "not_found", "message": "Unknown SDK endpoint"}"#.utf8))
                : .json(202, accepted)
        }
        let client = FeeqdClient.stubbed()
        await client.setIdentityToken("jwt.token.here")
        let receipt = try await client.submit(boardID: "B", title: "Dark mode", description: "Please")

        XCTAssertEqual(receipt.status, "queued")
        XCTAssertEqual(StubURLProtocol.requests.map { $0.url?.path }, ["/sdk/boards/B/entries", "/public/comment/B"])
        let request = try XCTUnwrap(StubURLProtocol.requests.last)
        XCTAssertNil(request.value(forHTTPHeaderField: "x-identity-token"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Feeqd-Device-Id"), "dev_test_device")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
        XCTAssertEqual(json["type"] as? String, "comment")
        XCTAssertEqual(json["source"] as? String, "api")
        XCTAssertFalse((json["source_id"] as? String ?? "").isEmpty)
        XCTAssertEqual((json["content"] as? [String: String])?["title"], "Dark mode")
    }

    func testResetForgetsTheUserAndTakesANewDevice() async throws {
        let body = try Fixture.data("comment_created")
        StubURLProtocol.responder = { _ in .json(201, body) }
        let client = FeeqdClient.stubbed()
        await client.setIdentityToken("jwt.token.here")
        await client.setClaimedIdentity(id: "user-42", name: "Marta", email: "marta@example.com")
        await client.reset()
        _ = try await client.comment(boardID: "B", entryID: "E", content: "Hi", parentID: nil)

        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertNil(request.value(forHTTPHeaderField: "x-identity-token"))
        XCTAssertNil(request.value(forHTTPHeaderField: "X-Feeqd-Claimed-Id"))
        let device = try XCTUnwrap(request.value(forHTTPHeaderField: "X-Feeqd-Device-Id"))
        XCTAssertNotEqual(device, "dev_test_device")
        XCTAssertEqual(device.count, 27)
    }

    func testFailuresMapToTypedErrors() async throws {
        let badKey = try Fixture.data("error_bad_key")
        StubURLProtocol.responder = { _ in .json(401, badKey) }
        do {
            _ = try await FeeqdClient.stubbed().config()
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? FeeqdError, .invalidKey)
        }

        StubURLProtocol.responder = { _ in .init(status: 429, headers: ["Retry-After": "12"]) }
        do {
            _ = try await FeeqdClient.stubbed().vote(boardID: "B", entryID: "E")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? FeeqdError, .rateLimited(retryAfter: 12))
            XCTAssertTrue((error as? FeeqdError)?.isRetryable ?? false)
        }
    }
}
