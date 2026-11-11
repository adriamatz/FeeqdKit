import FeeqdCore
import XCTest

/// The app's `canSubmit` and what the SDK knows of the user's payment, against the dashboard's
/// switches: the app can only turn the form into the alert, never bring back a "+" the
/// dashboard took away.
final class SubmitAccessTests: XCTestCase {
    private func config(submitEnabled: Bool = true, acceptingEntries: Bool = true, paidOnly: Bool = false) -> SDKConfig {
        var config = SDKConfig.fallback
        config.behaviour.submitEnabled = submitEnabled
        config.behaviour.submitPaidOnly = paidOnly
        config.acceptingEntries = acceptingEntries
        return config
    }

    private func resolve(_ config: SDKConfig, canSubmit: Bool? = nil, pays: Bool? = nil) -> SubmitAccess {
        SubmitAccess.resolve(config: config, canSubmit: canSubmit, pays: pays)
    }

    func testAnAllowedUserGetsTheForm() {
        XCTAssertEqual(resolve(config(), canSubmit: true), .form)
    }

    func testABlockedUserGetsTheAlertAndTheButtonStays() {
        XCTAssertEqual(resolve(config(), canSubmit: false), .blocked)
    }

    func testTheDashboardWinsOverTheApp() {
        XCTAssertEqual(resolve(config(submitEnabled: false), canSubmit: true), .hidden)
        XCTAssertEqual(resolve(config(submitEnabled: false), canSubmit: false), .hidden)
        XCTAssertEqual(resolve(config(acceptingEntries: false), canSubmit: true), .hidden, "a full plan shows its own notice")
        XCTAssertEqual(resolve(config(acceptingEntries: false), canSubmit: false), .hidden)
    }

    func testWithNothingSaidEveryoneGetsTheForm() {
        XCTAssertEqual(resolve(config()), .form)
        XCTAssertEqual(resolve(config(), pays: false), .form, "the switch is off")
    }

    func testPaidOnlyGoesByThePayment() {
        XCTAssertEqual(resolve(config(paidOnly: true), pays: true), .form)
        XCTAssertEqual(resolve(config(paidOnly: true), pays: false), .blocked)
    }

    func testPaidOnlyDoesNothingWhenTheSDKCantKnowWhoPays() {
        XCTAssertEqual(resolve(config(paidOnly: true), pays: nil), .form, "a whole app is never locked out by mistake")
    }

    func testTheAppsOwnSayWinsOverPaidOnly() {
        XCTAssertEqual(resolve(config(paidOnly: true), canSubmit: true, pays: false), .form)
        XCTAssertEqual(resolve(config(paidOnly: true), canSubmit: true, pays: nil), .form)
        XCTAssertEqual(resolve(config(paidOnly: true), canSubmit: false, pays: true), .blocked)
        XCTAssertEqual(resolve(config(paidOnly: true), canSubmit: false, pays: nil), .blocked)
    }

    func testPaidOnlyNeverBringsBackAHiddenButton() {
        XCTAssertEqual(resolve(config(submitEnabled: false, paidOnly: true), pays: true), .hidden)
        XCTAssertEqual(resolve(config(acceptingEntries: false, paidOnly: true), pays: true), .hidden)
    }

    func testTheFlagIsReadFromTheConfigAndOffWhenMissing() throws {
        let on = try JSONDecoder().decode(SDKConfig.Behaviour.self, from: Data(#"{"submitPaidOnly":true}"#.utf8))
        XCTAssertTrue(on.submitPaidOnly)
        let missing = try JSONDecoder().decode(SDKConfig.Behaviour.self, from: Data("{}".utf8))
        XCTAssertFalse(missing.submitPaidOnly)
    }

    func testTheGateStartsWhereTheConfigurationSaysAndChangesAtRuntime() {
        XCTAssertNil(SubmitGate().canSubmit, "the dashboard decides unless the app says otherwise")
        XCTAssertNil(SubmitGate().pays, "no way to know who pays")
        XCTAssertEqual(SubmitGate(readsPurchases: true).pays, false, "not paying until the App Store says so")
        let gate = SubmitGate(canSubmit: false)
        XCTAssertEqual(gate.canSubmit, false)
        gate.set(true)
        XCTAssertEqual(gate.canSubmit, true, "a user who subscribes mid-session can add requests at once")
        gate.set(nil)
        XCTAssertNil(gate.canSubmit, "back to the dashboard")
    }

    func testAPaymentMakesTheGateKnowWhoPays() {
        let gate = SubmitGate()
        gate.setPays(true)
        XCTAssertEqual(gate.pays, true)
        gate.setPays(false)
        XCTAssertEqual(gate.pays, false, "a lapsed payment blocks, it doesn't switch the rule off")
    }

    @MainActor
    func testAChangeIsAnnouncedOnceAndARepeatIsNot() async {
        let gate = SubmitGate(canSubmit: false)
        let announced = expectation(forNotification: SubmitGate.didChange, object: gate)
        gate.set(true)
        await fulfillment(of: [announced], timeout: 1)

        let repeated = expectation(forNotification: SubmitGate.didChange, object: gate)
        repeated.isInverted = true
        gate.set(true)
        await fulfillment(of: [repeated], timeout: 0.2)
    }

    @MainActor
    func testAPaymentChangeIsAnnounced() async {
        let gate = SubmitGate(readsPurchases: true)
        let announced = expectation(forNotification: SubmitGate.didChange, object: gate)
        gate.setPays(true)
        await fulfillment(of: [announced], timeout: 1)
    }
}
