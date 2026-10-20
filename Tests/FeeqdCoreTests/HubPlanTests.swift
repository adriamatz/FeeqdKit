import FeeqdCore
import XCTest

final class HubPlanTests: XCTestCase {
    private func config(_ json: String) throws -> SDKConfig {
        try JSONDecoder.feeqd.decode(SDKConfig.self, from: Data(json.utf8))
    }

    private let twoBoards = """
    "board_id": "ideas",
    "boards": [
      {"id": "ideas", "title": "Feature requests", "board_type": "feature_requests", "is_public": true,
       "statuses": [{"slug": "pending", "label": "Pending", "category": "open", "position": 0}]},
      {"id": "bugs", "title": "Bugs", "board_type": "bugs_fixes", "is_public": true,
       "statuses": [{"slug": "reported", "label": "Reported", "category": "open", "position": 0}]}
    ]
    """

    func testWithoutALayoutTheHubIsTheFirstBoardAsBefore() throws {
        let plan = HubPlan.make(config: try config("{\(twoBoards)}"), preferredBoardID: nil)

        XCTAssertEqual(plan.sections.map(\.id), ["ideas"])
        XCTAssertEqual(plan.style, .single)
        XCTAssertFalse(plan.chatEnabled, "the chat is off until the team turns it on in the dashboard")
    }

    func testABackendWithoutBoardsStillShowsItsOneBoard() throws {
        let plan = HubPlan.make(config: try config(#"{"board_id": "legacy"}"#), preferredBoardID: nil)
        XCTAssertEqual(plan.sections.map(\.boardID), ["legacy"])
    }

    func testTheLayoutDecidesSectionsOrderLabelsAndChat() throws {
        let json = """
        {\(twoBoards), "behaviour": {"layout": {"style": "menu", "title": "Help",
          "sections": [
            {"id": "bugs", "kind": "board", "label": "Problems", "enabled": true},
            {"id": "roadmap", "kind": "roadmap", "label": "", "enabled": true},
            {"id": "ideas", "kind": "board", "label": "", "enabled": false},
            {"id": "chat", "kind": "chat", "label": "", "enabled": false}
          ]}}}
        """
        let plan = HubPlan.make(config: try config(json), preferredBoardID: nil)

        XCTAssertEqual(plan.sections.map(\.id), ["bugs", "roadmap"], "the admin's order, switched-off boards left out")
        XCTAssertEqual(plan.sections.first?.label, "Problems")
        XCTAssertEqual(plan.sections.first?.kind, .board(id: "bugs", isBugs: true))
        XCTAssertEqual(plan.style, .menu)
        XCTAssertEqual(plan.title, "Help")
        XCTAssertFalse(plan.chatEnabled)
    }

    func testUnknownValuesFromANewerDashboardNeverBreakAnOldApp() throws {
        let json = """
        {\(twoBoards), "behaviour": {"layout": {"style": "carousel",
          "sections": [
            {"id": "x", "kind": "poll", "enabled": true},
            {"id": "ideas", "kind": "board", "enabled": true},
            {"id": "gone", "kind": "board", "enabled": true}
          ]}}}
        """
        let plan = HubPlan.make(config: try config(json), preferredBoardID: nil)

        XCTAssertEqual(plan.sections.map(\.id), ["ideas"], "an unknown kind and a deleted board drop out")
        XCTAssertEqual(plan.style, .single, "an unknown style reads as auto; one section needs no switcher")
    }

    func testEveryBoardSwitchedOffStillLeavesTheFirstOne() throws {
        let json = """
        {\(twoBoards), "behaviour": {"layout": {"sections": [
            {"id": "ideas", "kind": "board", "enabled": false},
            {"id": "bugs", "kind": "board", "enabled": false},
            {"id": "roadmap", "kind": "roadmap", "enabled": true}
        ]}}}
        """
        let plan = HubPlan.make(config: try config(json), preferredBoardID: nil)
        XCTAssertEqual(plan.sections.map(\.id), ["ideas", "roadmap"], "never a hub with nothing to ask in")
    }

    func testAutomaticMatchesTheDashboardPreview() {
        XCTAssertEqual(HubPlan.resolve(.auto, sectionCount: 1), .single)
        XCTAssertEqual(HubPlan.resolve(.auto, sectionCount: 3), .bar)
        XCTAssertEqual(HubPlan.resolve(.auto, sectionCount: 4), .chips)
        XCTAssertEqual(HubPlan.resolve(.home, sectionCount: 1), .home)
        XCTAssertEqual(HubPlan.resolve(.menu, sectionCount: 1), .single)
    }

    func testEachBoardStoreSeesItsOwnStatuses() throws {
        let scoped = try config("{\(twoBoards)}").scoped(to: "bugs")
        XCTAssertEqual(scoped.boardID, "bugs")
        XCTAssertEqual(scoped.statuses.map(\.slug), ["reported"])
    }

    func testRoadmapColumnsFallBackToTheDefaults() throws {
        let plan = HubPlan.make(config: try config("""
        {\(twoBoards), "behaviour": {"layout": {"sections": [{"id": "roadmap", "kind": "roadmap"}], "roadmap": {"columns": []}}}}
        """), preferredBoardID: nil)
        XCTAssertEqual(plan.columns.map(\.id), ["next", "now", "shipped"])
    }

    func testTheRoadmapKeepsTheAdminsHandOrder() throws {
        let plan = HubPlan.make(config: try config("""
        {\(twoBoards), "behaviour": {"layout": {"sections": [{"id": "roadmap", "kind": "roadmap"}],
          "roadmap": {"order": ["e2", 7, "e1"]}}}}
        """), preferredBoardID: nil)
        XCTAssertEqual(plan.order, ["e2", "e1"], "a value that is not an id drops out, the rest keep their place")
    }

    func testTheAppCanShowATeamRoadmapInsteadOfStatuses() throws {
        let plan = HubPlan.make(config: try config("""
        {\(twoBoards), "behaviour": {"layout": {"sections": [{"id": "roadmap", "kind": "roadmap"}],
          "roadmap": {"roadmapId": "r1"}}}}
        """), preferredBoardID: nil)
        XCTAssertEqual(plan.roadmapID, "r1")

        let byStatus = HubPlan.make(config: try config("""
        {\(twoBoards), "behaviour": {"layout": {"sections": [{"id": "roadmap", "kind": "roadmap"}],
          "roadmap": {"roadmapId": ""}}}}
        """), preferredBoardID: nil)
        XCTAssertNil(byStatus.roadmapID, "an empty id means by status")
    }

    func testATeamRoadmapDecodesFromThePublicReader() throws {
        // The shape of the local stack's GET /public/roadmap/{id} on 2026-09-28.
        let entries = try FeeqdClient.decodeRoadmapEntries(try Fixture.data("roadmap_detail"))
        XCTAssertEqual(entries.count, 2)
        XCTAssertTrue(entries.contains { $0.title == "iCloud sync between iPhone and iPad" && $0.state == "planned" })
    }
}
