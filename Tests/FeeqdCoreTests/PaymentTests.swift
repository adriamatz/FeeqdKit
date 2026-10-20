@testable import FeeqdCore
import XCTest

final class PaymentTests: XCTestCase {
    func testEveryPeriodBecomesAMonthlyFigure() {
        XCTAssertEqual(PaymentSummary(period: .month, amount: 4.99, currency: "EUR", source: .storekit).monthlyAmount, 4.99)
        XCTAssertEqual(PaymentSummary(period: .year, amount: 60, currency: "EUR", source: .storekit).monthlyAmount, 5)
        XCTAssertEqual(PaymentSummary(period: .week, amount: 3, currency: "USD", source: .storekit).monthlyAmount, 13)
        XCTAssertNil(PaymentSummary(period: .lifetime, amount: 29.99, currency: "USD", source: .storekit).monthlyAmount,
                     "a one-off purchase is not recurring revenue")
    }

    func testTheHeaderIsPlainAsciiTheServerCanSplit() {
        let payment = PaymentSummary(period: .year, amount: 39.99, currency: "EUR", productID: "pro.yearly+promo",
                                     isTrial: true, environment: "sandbox", source: .storekit)
        let pairs = Dictionary(uniqueKeysWithValues: payment.headerValue.split(separator: "&").map {
            let kv = $0.split(separator: "=", maxSplits: 1)
            return (String(kv[0]), String(kv[1]).removingPercentEncoding ?? "")
        })
        XCTAssertEqual(pairs["period"], "year")
        XCTAssertEqual(pairs["amount"], "39.99")
        XCTAssertEqual(pairs["currency"], "EUR")
        XCTAssertEqual(pairs["trial"], "1")
        XCTAssertEqual(pairs["env"], "sandbox")
        XCTAssertEqual(pairs["product"], "pro.yearly+promo")
        XCTAssertTrue(payment.headerValue.allSatisfy(\.isASCII))
    }

    func testThePriciestRecurringPlanWinsAndBeatsALifetimePurchase() {
        let monthly = PaymentSummary(period: .month, amount: 4.99, currency: "USD", source: .storekit)
        let yearly = PaymentSummary(period: .year, amount: 99.99, currency: "USD", source: .storekit)
        let lifetime = PaymentSummary(period: .lifetime, amount: 199, currency: "USD", source: .storekit)
        XCTAssertEqual(StoreKitPayments.better(monthly, yearly), yearly)
        XCTAssertEqual(StoreKitPayments.better(lifetime, monthly), monthly)
        XCTAssertEqual(StoreKitPayments.better(nil, lifetime), lifetime)
    }

    /// A StoreKit read that began before `reset()` answers after it: it must not hand the
    /// previous user's payment to the next one.
    func testResetDropsTheStorePaymentAndAStaleReadOfIt() async {
        let client = FeeqdClient.stubbed()
        let yearly = PaymentSummary(period: .year, amount: 60, currency: "EUR", source: .storekit)
        let before = await client.paymentGeneration
        await client.setStorePayment(yearly, generation: before)
        let stored = await client.payment
        XCTAssertEqual(stored, yearly)

        await client.reset()
        let afterReset = await client.payment
        XCTAssertNil(afterReset)

        await client.setStorePayment(yearly, generation: before)
        let afterStaleRead = await client.payment
        XCTAssertNil(afterStaleRead, "a read from before the reset is dropped")

        await client.setStorePayment(yearly, generation: await client.paymentGeneration)
        let afterFreshRead = await client.payment
        XCTAssertEqual(afterFreshRead, yearly)
    }
}
