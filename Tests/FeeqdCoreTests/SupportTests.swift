import FeeqdCore
import XCTest

final class SupportTests: XCTestCase {
    func testDatesInEveryShapeTheAPISends() throws {
        let micro = try XCTUnwrap(FeeqdDate.parse("2026-09-11T07:18:14.187766"))
        let plain = try XCTUnwrap(FeeqdDate.parse("2026-09-11T07:18:14"))
        let zoned = try XCTUnwrap(FeeqdDate.parse("2026-09-11T07:18:14Z"))
        XCTAssertEqual(plain, zoned, "a date without a zone is UTC")
        XCTAssertEqual(micro.timeIntervalSince(plain), 0.187, accuracy: 0.001)
        XCTAssertNil(FeeqdDate.parse("yesterday"))
    }

    func testKSUIDShape() {
        let ids = (0..<200).map { _ in KSUID.generate() }
        XCTAssertTrue(ids.allSatisfy { $0.count == KSUID.length })
        XCTAssertTrue(ids.allSatisfy { $0.allSatisfy { $0.isLetter || $0.isNumber } })
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testKSUIDSortsByTime() {
        let earlier = KSUID.generate(now: Date(timeIntervalSince1970: 1_700_000_000))
        let later = KSUID.generate(now: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertLessThan(earlier, later)
    }

    func testDeviceIDIsGeneratedOnceAndReused() async throws {
        let store = InMemorySecretStore()
        let first = try await DeviceIdentity(store: store).deviceID()
        let second = try await DeviceIdentity(store: store).deviceID()
        XCTAssertEqual(first, second)
        XCTAssertEqual(try store.read(account: DeviceIdentity.account), first)
    }

    func testALockedStoreNeverMintsASecondDeviceID() async throws {
        let store = InMemorySecretStore([DeviceIdentity.account: "dev_real"])
        store.setLocked(true)
        let identity = DeviceIdentity(store: store)
        do {
            _ = try await identity.deviceID()
            XCTFail("a locked store must not hand out an id")
        } catch {}

        store.setLocked(false)
        let id = try await identity.deviceID()
        XCTAssertEqual(id, "dev_real")
        XCTAssertEqual(try store.read(account: DeviceIdentity.account), "dev_real")
    }

    func testADeviceIDThatCouldNotBeSavedIsSavedLater() async throws {
        let store = FailingWrites()
        let identity = DeviceIdentity(store: store)
        let first = try await identity.deviceID()
        XCTAssertNil(try store.read(account: DeviceIdentity.account))

        store.allowWrites()
        let second = try await identity.deviceID()
        XCTAssertEqual(first, second)
        XCTAssertEqual(try store.read(account: DeviceIdentity.account), first)
    }

    func testAResetThatCouldNotBeSavedIsSavedLater() async throws {
        let store = FailingWrites(["device-id": "dev_previous_user"])
        let identity = DeviceIdentity(store: store)
        await identity.reset()
        store.allowWrites()
        let id = try await identity.deviceID()
        XCTAssertNotEqual(id, "dev_previous_user")
        XCTAssertEqual(try store.read(account: DeviceIdentity.account), id)
    }

    func testACancelledRequestStaysACancellation() async {
        let client = FeeqdClient.stubbed()
        let task = Task { try await client.myVotes(boardID: "B") }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("a cancelled request must not answer")
        } catch {
            XCTAssertTrue(FeeqdError.isCancellation(error), "got \(error)")
        }
    }

    func testARequestFailsWhileTheDeviceIDIsLocked() async {
        let store = InMemorySecretStore([DeviceIdentity.account: "dev_real"])
        store.setLocked(true)
        let client = FeeqdClient.stubbed(identity: DeviceIdentity(store: store))
        do {
            _ = try await client.myVotes(boardID: "B")
            XCTFail("the request must not go out without the device id")
        } catch let error as FeeqdError {
            XCTAssertTrue(error.isRetryable)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testStringResolutionOrder() {
        let remote = ["es": ["board.title": "Ideas"], "es_MX": ["submit.cta": "Pide algo"]]
        let mexico = StringTable(remote: remote, languages: ["es-MX"])
        XCTAssertEqual(mexico(.submitCTA), "Pide algo", "remote copy for the exact locale")
        XCTAssertEqual(mexico(.boardTitle), "Ideas", "remote copy for the base language")
        XCTAssertEqual(mexico(.submitSend), "Enviar", "bundled Spanish")

        let overridden = StringTable(overrides: ["board.title": "Roadmap"], remote: remote, languages: ["es-MX"])
        XCTAssertEqual(overridden(.boardTitle), "Roadmap", "code wins over everything")

        let russian = StringTable(languages: ["ru-RU"])
        XCTAssertEqual(russian(.submitSend), "Send", "falls back to English")
    }

    func testStatusesAreTranslatedUntilRenamed() {
        let spanish = StringTable(languages: ["es-ES"])
        XCTAssertEqual(spanish.status("Planned", slug: "planned"), "Previsto")
        XCTAssertEqual(spanish.status("Fixing", slug: "in_progress"), "Arreglando", "a bug board's in_progress")
        XCTAssertEqual(spanish.status("Next up", slug: "planned"), "Next up", "a renamed status keeps the team's name")
        XCTAssertEqual(spanish.status(nil, slug: "known_issue"), "Known Issue", "an unknown status reads its slug")

        let team = StringTable(remote: ["es": ["status.planned": "Lo haremos"]], languages: ["es-ES"])
        XCTAssertEqual(team.status("Planned", slug: "planned"), "Lo haremos", "the team's text for the language")
    }

    func testCustomNamesAreOnlyTheTeams() {
        let table = StringTable(
            remote: ["es": ["hub.board.bX1": "Ideas", "hub.roadmap": " "]],
            languages: ["es-MX"]
        )
        XCTAssertEqual(table.custom("hub.board.bX1"), "Ideas", "found through the base language")
        XCTAssertNil(table.custom("hub.roadmap"), "a blank name is no name")
        XCTAssertNil(StringTable(languages: ["en"]).custom("hub.board.bX1"), "no bundled fallback")
    }

    func testTheDashboardCanHideTheNoteAndKeepIt() throws {
        let hidden = try JSONDecoder().decode(SDKConfig.Behaviour.self, from: Data(#"{"listNoteHidden":true}"#.utf8))
        XCTAssertTrue(hidden.listNoteHidden)
        let missing = try JSONDecoder().decode(SDKConfig.Behaviour.self, from: Data("{}".utf8))
        XCTAssertFalse(missing.listNoteHidden, "a written note shows unless the dashboard hides it")
    }

    func testTheTeamsNoteShowsOnlyWhenWritten() {
        let table = StringTable(
            remote: ["es": ["list.note": "  Estamos con la sincronización.\n"], "en": ["list.note": ""]],
            languages: ["es-MX"]
        )
        XCTAssertEqual(table.listNote, "Estamos con la sincronización.", "the team's text for the language, trimmed")
        XCTAssertNil(StringTable(remote: ["en": ["list.note": ""]], languages: ["en"]).listNote, "empty means hidden")
        XCTAssertNil(StringTable(remote: ["en": ["list.note": " \n"]], languages: ["en"]).listNote, "blank lines are empty")
        XCTAssertNil(StringTable(languages: ["en"]).listNote, "nothing bundled")
        XCTAssertEqual(StringTable(remote: ["en": ["list.note": "Out next week"]], languages: ["de"]).listNote, "Out next week", "the English one for a language with none")
        XCTAssertNil(StringTable(remote: ["es": ["list.note": "La semana que viene"]], languages: ["de"]).listNote, "never another language's")
    }

    func testAReviewRequestReadsInTheUsersLanguage() {
        let spanish = StringTable(remote: ["en": ["review.message": "Rate us, please!"]], languages: ["es-ES"])
        let stock = "If the app helps you, a review on the App Store would mean a lot to us."
        XCTAssertEqual(spanish.reviewMessage(stock), "Si la app te ayuda, una reseña en la App Store nos ayudaría mucho.")
        XCTAssertEqual(spanish.reviewMessage("Rate us, please!\n"), spanish(.reviewMessage), "the team's saved text, in any language")
        XCTAssertEqual(spanish.reviewMessage("Thanks for the report! Mind rating us?"), "Thanks for the report! Mind rating us?", "typed by hand")

        let team = StringTable(remote: ["es": ["review.message": "¿Nos dejas una reseña?"]], languages: ["es-MX"])
        XCTAssertEqual(team.reviewMessage(stock), "¿Nos dejas una reseña?", "the team's own text for the language")
    }

    func testScriptsAndRegionsFindTheirTable() {
        XCTAssertEqual(StringTable(languages: ["zh-Hans-US"])(.tabDone), "已完成", "iOS puts the script before the region")
        XCTAssertEqual(StringTable(languages: ["zh-Hant-TW"])(.boardTitle), "意見回饋")
        XCTAssertEqual(StringTable(languages: ["pt-PT"])(.submitSend), StringTable(languages: ["pt-BR"])(.submitSend), "Portugal reads Brazil's")
        XCTAssertEqual(StringTable(languages: ["nb-NO"])(.tabOpen), "Åpne")
    }

    func testBundledTablesAreComplete() {
        for language in StringTable.bundled.keys.sorted() {
            let table = StringTable.bundled[language] ?? [:]
            let missing = StringKey.allCases.map(\.rawValue).filter { table[$0] == nil }
            XCTAssertEqual(missing, [], "\(language) is missing keys")
        }
    }

    func testHexColors() {
        XCTAssertEqual(HexColor.parse("#0055FF"), RGBA(red: 0, green: 85.0 / 255, blue: 1, alpha: 1))
        XCTAssertEqual(HexColor.parse("fff"), RGBA(red: 1, green: 1, blue: 1, alpha: 1))
        XCTAssertEqual(HexColor.parse("#00000080")?.alpha ?? 0, 128.0 / 255, accuracy: 0.0001)
        XCTAssertNil(HexColor.parse("#GGGGGG"))
        XCTAssertNil(HexColor.parse("#12345"))
    }

    func testDeviceInfoFitsTheServerLimit() throws {
        let header = try XCTUnwrap(DeviceInfo.headerValue(sdkVersion: "0.1.0", appVersion: "2.4.0"))
        XCTAssertLessThanOrEqual(header.utf8.count, 512)
        let info = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(header.utf8)) as? [String: String])
        XCTAssertEqual(info["sdk"], "0.1.0")
        XCTAssertEqual(info["app"], "2.4.0")
        XCTAssertNotNil(info["model"])
        XCTAssertNotNil(info["os"])
    }
}

/// A store that can be read but refuses writes until told otherwise.
private final class FailingWrites: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String]
    private var writable = false

    init(_ values: [String: String] = [:]) { self.values = values }

    func allowWrites() {
        lock.lock()
        writable = true
        lock.unlock()
    }

    func read(account: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values[account]
    }

    @discardableResult
    func write(_ value: String, account: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard writable else { return false }
        values[account] = value
        return true
    }
}
