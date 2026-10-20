import FeeqdCore
import XCTest

final class DecodingTests: XCTestCase {
    func testConfigDecodesTheCapturedResponse() throws {
        let config = try Fixture.decode(SDKConfig.self, "sdk_config")
        XCTAssertEqual(config.boardID, "0003BNsEyndh34CwVCh2UokMmOD")
        XCTAssertEqual(config.colors["primary"], ColorPair(light: "#0055FF", dark: "#4488FF"))
        XCTAssertEqual(config.cornerRadius, 12)
        XCTAssertEqual(config.behaviour.tabs, [.open, .done])
        XCTAssertEqual(config.behaviour.defaultSort, .votes)
        XCTAssertEqual(config.behaviour.emailField, .optional)
        XCTAssertFalse(config.behaviour.poweredByFeeqd)
        XCTAssertEqual(config.strings["es"]?["board.title"], "Sugerencias")
        XCTAssertEqual(config.statuses.map(\.slug), ["pending", "planned", "in_review", "in_progress", "completed"])
        XCTAssertEqual(config.statuses.last?.category, .closed)
        XCTAssertEqual(config.statuses.first?.color, ColorPair(light: "#8E8E93", dark: "#8E8E93"))
    }

    /// A value added tomorrow must not break a build already on the App Store.
    func testConfigIgnoresWhatItDoesNotKnow() throws {
        let json = """
        {
          "schema_version": 2,
          "theme": {"colors": {"primary": {"light": "#000000", "dark": "#FFFFFF"}, "sparkle": 7}, "fontScale": "system"},
          "behaviour": {"tabs": ["open", "trending", "mine"], "defaultSort": "hot", "brandNewFlag": true},
          "statuses": [{"slug": "planned", "label": "Planned", "category": "someday", "position": 1}, {"nope": true}],
          "future_section": {"anything": 1}
        }
        """
        let config = try JSONDecoder.feeqd.decode(SDKConfig.self, from: Data(json.utf8))
        XCTAssertEqual(config.colors.keys.sorted(), ["primary"])
        XCTAssertEqual(config.behaviour.tabs, [.open, .mine])
        XCTAssertEqual(config.behaviour.defaultSort, .votes)
        XCTAssertEqual(config.statuses.map(\.slug), ["planned"])
        XCTAssertEqual(config.statuses.first?.category, .open)
        XCTAssertNil(config.boardID)
    }

    func testConfigReadsTheQuotaSignals() throws {
        let older = try JSONDecoder.feeqd.decode(SDKConfig.self, from: Data("{}".utf8))
        XCTAssertTrue(older.acceptingEntries, "a backend without the field never hides the button")
        XCTAssertTrue(older.acceptingConversations)

        let full = try JSONDecoder.feeqd.decode(
            SDKConfig.self, from: Data(#"{"accepting_entries": false, "accepting_conversations": false}"#.utf8)
        )
        XCTAssertFalse(full.acceptingEntries)
        XCTAssertFalse(full.acceptingConversations)
    }

    func testEntriesPageDecodes() throws {
        let page = try Fixture.decode(Page<Entry>.self, "entries_page")
        XCTAssertEqual(page.items.count, 3)
        XCTAssertEqual(page.pagination.totalItems, 3)
        XCTAssertFalse(page.pagination.hasNext)
        let first = try XCTUnwrap(page.items.first)
        XCTAssertEqual(first.title, "Dark mode for the reading view")
        XCTAssertEqual(first.details, "The white page at night is brutal.")
        XCTAssertEqual(first.voteCount, 1)
        XCTAssertEqual(first.commentCount, 2)
        XCTAssertEqual(first.state, "pending")
        XCTAssertNil(first.authorName)
        // An empty description is no description.
        XCTAssertNil(page.items.first { $0.title == "Widget for the home screen" }?.details)
    }

    func testOneBrokenRowDoesNotTakeThePageDown() throws {
        let json = """
        {"items": [
          {"id": "a", "board_id": "b", "content": {"title": "Fine"}, "state": "pending", "created_at": "2026-09-11T07:18:14.187766"},
          {"id": "b", "board_id": "b", "content": {"title": "No date"}},
          {"id": "c", "board_id": "b", "content": {"title": "Also fine"}, "created_at": "2026-09-11T07:18:14"}
        ], "pagination": {"page": 1, "page_size": 20, "total_items": 3, "total_pages": 1, "has_next": false}}
        """
        let page = try JSONDecoder.feeqd.decode(Page<Entry>.self, from: Data(json.utf8))
        XCTAssertEqual(page.items.map(\.id), ["a", "c"])
    }

    func testEntryDetailAndSearchDecode() throws {
        let entry = try Fixture.decode(Entry.self, "entry_detail")
        XCTAssertEqual(entry.id, "0003BNsEyoDrlLzjZ55HPXmoCv3")
        let search = try Fixture.decode(Page<Entry>.self, "entries_search")
        XCTAssertEqual(search.items.first?.title, "Export notes to Kindle")
    }

    func testCommentsDecodeFlatWithParents() throws {
        let page = try Fixture.decode(Page<Comment>.self, "comments_page")
        XCTAssertEqual(page.items.count, 2)
        XCTAssertNil(page.items[0].parentID)
        XCTAssertEqual(page.items[1].parentID, page.items[0].id)
        XCTAssertFalse(page.items[0].isTeamMember)
    }

    func testWriteResponsesDecode() throws {
        let vote = try Fixture.decode(VoteResult.self, "vote_cast")
        XCTAssertEqual(vote.voteCount, 1)
        XCTAssertTrue(vote.voted)
        let retracted = try Fixture.decode(VoteResult.self, "vote_retracted")
        XCTAssertFalse(retracted.voted)
        XCTAssertEqual(try Fixture.decode(MyVotes.self, "my_votes").entryIDs, ["0003BNsEyoDrlLzjZ55HPXmoCv3"])
        let receipt = try Fixture.decode(SubmitReceipt.self, "submit_accepted")
        XCTAssertEqual(receipt.status, "queued")
        let comment = try Fixture.decode(CreatedComment.self, "comment_created")
        XCTAssertTrue(comment.isPublished)
        XCTAssertNotNil(comment.createdAt, "a created comment's date has no fraction; it must still parse")
        XCTAssertEqual(try Fixture.decode(SimilarResponse.self, "similar").items, [])
    }

    func testErrorBodiesFromBothServicesMap() throws {
        XCTAssertEqual(FeeqdError.from(status: 401, data: try Fixture.data("error_bad_key"), retryAfter: nil), .invalidKey)
        XCTAssertEqual(
            FeeqdError.from(status: 400, data: try Fixture.data("error_device_id_required"), retryAfter: nil),
            .server(status: 400, code: "device_id_required", message: "X-Feeqd-Device-Id header is required")
        )
        let unknownRoute = FeeqdError.from(status: 404, data: try Fixture.data("error_unknown_endpoint"), retryAfter: nil)
        XCTAssertEqual(unknownRoute, .notFound(code: "not_found"))
        XCTAssertTrue(unknownRoute.isMissingRoute)
        XCTAssertTrue(FeeqdError.from(status: 404, data: Data(), retryAfter: nil).isMissingRoute)
        let board = Data(#"{"error": "board_not_found", "message": "Board not found"}"#.utf8)
        XCTAssertEqual(FeeqdError.from(status: 404, data: board, retryAfter: nil), .notFound(code: "board_not_found"))
        XCTAssertFalse(FeeqdError.from(status: 404, data: board, retryAfter: nil).isMissingRoute)
        let reader = Data(#"{"detail": "Feedback board not found"}"#.utf8)
        XCTAssertTrue(FeeqdError.from(status: 404, data: reader, retryAfter: nil).isMissingRoute)
        let identity = Data(#"{"error": "identity_required", "message": "Identity token required"}"#.utf8)
        XCTAssertEqual(FeeqdError.from(status: 401, data: identity, retryAfter: nil), .identityRequired)
        XCTAssertEqual(FeeqdError.from(status: 429, data: Data(), retryAfter: "30"), .rateLimited(retryAfter: 30))
    }
}
