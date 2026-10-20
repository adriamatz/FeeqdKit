import Foundation
import StoreKit

/// What a user pays for the host app, as the dashboard weighs requests with it: an amount per
/// billing period in the store's currency. Converting to one currency happens on the server,
/// which has the day's rates; the device only reports what the store says.
package struct PaymentSummary: Equatable, Sendable {
    package enum Period: String, Sendable { case week, month, year, lifetime }
    package enum Source: String, Sendable { case storekit, manual }

    package var period: Period
    /// The list price for one period, in `currency` — what the user pays once any trial ends.
    package var amount: Decimal
    package var currency: String
    package var productID: String?
    /// In a free trial or an introductory offer: counted as paying nothing yet.
    package var isTrial: Bool
    /// Shared through Family Sharing: someone else pays.
    package var isFamilyShared: Bool
    /// `production`, `sandbox` or `xcode`, so test purchases never count as revenue.
    package var environment: String
    package var source: Source

    package init(
        period: Period,
        amount: Decimal,
        currency: String,
        productID: String? = nil,
        isTrial: Bool = false,
        isFamilyShared: Bool = false,
        environment: String = "production",
        source: Source
    ) {
        self.period = period
        self.amount = amount
        self.currency = currency
        self.productID = productID
        self.isTrial = isTrial
        self.isFamilyShared = isFamilyShared
        self.environment = environment
        self.source = source
    }

    /// The same amount per month; nil for a one-off purchase, which is not recurring revenue.
    package var monthlyAmount: Decimal? {
        switch period {
        case .week: return amount * 52 / 12
        case .month: return amount
        case .year: return amount / 12
        case .lifetime: return nil
        }
    }

    /// Cents are enough: a price split over several periods, or a literal written as a Double,
    /// would otherwise travel with a tail of float noise.
    static func rounded(_ value: Decimal) -> Decimal {
        var input = value
        var output = Decimal()
        NSDecimalRound(&output, &input, 2, .plain)
        return output
    }

    /// `X-Feeqd-User-Payment`: form-encoded, ASCII, easy to read on the server.
    package var headerValue: String {
        var items = [
            ("period", period.rawValue),
            ("amount", NSDecimalNumber(decimal: Self.rounded(amount)).stringValue),
            ("currency", currency),
            ("trial", isTrial ? "1" : "0"),
            ("family", isFamilyShared ? "1" : "0"),
            ("env", environment),
            ("source", source.rawValue),
        ]
        if let productID { items.append(("product", productID)) }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return items
            .map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&")
    }
}

/// Reads what the user currently pays from StoreKit 2, in the host app's process. It only
/// reads: it never finishes a transaction, never syncs with the App Store (that would ask the
/// user to sign in) and never listens for updates in competition with the app's own listener.
package enum StoreKitPayments {
    /// The most valuable thing the user holds: the priciest active subscription per month, or
    /// else a lifetime purchase. Nil when they hold nothing, or StoreKit has nothing to say.
    package static func current() async -> PaymentSummary? {
        var best: PaymentSummary?
        for await result in Transaction.currentEntitlements {
            guard case let .verified(transaction) = result, transaction.revocationDate == nil else { continue }
            guard let summary = await summary(for: transaction) else { continue }
            best = better(best, summary)
        }
        return best
    }

    static func better(_ a: PaymentSummary?, _ b: PaymentSummary) -> PaymentSummary {
        guard let a else { return b }
        switch (a.monthlyAmount, b.monthlyAmount) {
        case let (x?, y?): return y > x ? b : a
        case (nil, _?): return b          // recurring beats one-off
        case (_?, nil): return a
        case (nil, nil): return b.amount > a.amount ? b : a
        }
    }

    private static func summary(for transaction: Transaction) async -> PaymentSummary? {
        guard let product = try? await Product.products(for: [transaction.productID]).first else { return nil }
        let currency = product.priceFormatStyle.currencyCode
        let period: PaymentSummary.Period
        var amount = product.price
        switch product.type {
        case .autoRenewable, .nonRenewable:
            guard let subscription = product.subscription else { return nil }
            let unit = subscription.subscriptionPeriod
            switch unit.unit {
            case .day:
                period = .month
                amount = product.price * 30 / Decimal(max(unit.value, 1))
            case .week:
                period = .week
                amount = product.price / Decimal(max(unit.value, 1))
            case .month:
                period = .month
                amount = product.price / Decimal(max(unit.value, 1))
            case .year:
                period = .year
                amount = product.price / Decimal(max(unit.value, 1))
            @unknown default:
                return nil
            }
        case .nonConsumable:
            period = .lifetime
        default:
            return nil
        }

        return PaymentSummary(
            period: period,
            amount: amount,
            currency: currency,
            productID: transaction.productID,
            isTrial: isIntroductory(transaction),
            isFamilyShared: transaction.ownershipType == .familyShared,
            environment: environment(of: transaction),
            source: .storekit
        )
    }

    private static func isIntroductory(_ transaction: Transaction) -> Bool {
        if #available(iOS 17.2, macOS 14.2, *) {
            return transaction.offer?.type == .introductory
        }
        return transaction.offerType == .introductory
    }

    private static func environment(of transaction: Transaction) -> String {
        if #available(iOS 16.0, macOS 13.0, *) {
            switch transaction.environment {
            case .production: return "production"
            case .sandbox: return "sandbox"
            case .xcode: return "xcode"
            default: return "unknown"
            }
        }
        return "unknown"
    }
}
