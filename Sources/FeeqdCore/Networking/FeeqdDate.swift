import Foundation

/// Dates as the API sends them.
///
/// Captured from the local stack: `2026-09-11T07:18:14.187766` (no zone, microseconds) on
/// entries and comments, `2026-09-11T07:18:14` (no zone, no fraction) on a comment that was
/// just created. Both are UTC. A zoned ISO 8601 date is accepted too, so the day the backend
/// starts sending the `Z` nothing breaks.
package enum FeeqdDate {
    package static func parse(_ string: String) -> Date? {
        if let zoned = zoned(string) { return zoned }
        guard let dot = string.firstIndex(of: ".") else { return plain.date(from: string) }
        // DateFormatter reads milliseconds, not microseconds: keep the first three digits.
        let fraction = string[string.index(after: dot)...].prefix(while: \.isNumber)
        let millis = String(fraction.prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0)
        return fractional.date(from: String(string[..<dot]) + "." + millis)
    }

    package static func decode(_ decoder: Decoder) throws -> Date {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let date = parse(string) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unrecognised date: \(string)")
        }
        return date
    }

    private static func zoned(_ string: String) -> Date? {
        let hasZone = string.hasSuffix("Z") || string.range(of: #"[+-]\d{2}:?\d{2}$"#, options: .regularExpression) != nil
        guard hasZone else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    private static let plain = utcFormatter("yyyy-MM-dd'T'HH:mm:ss")
    private static let fractional = utcFormatter("yyyy-MM-dd'T'HH:mm:ss.SSS")

    private static func utcFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = format
        return formatter
    }
}

extension JSONDecoder {
    /// A decoder that reads the API's dates.
    package static var feeqd: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { try FeeqdDate.decode($0) }
        return decoder
    }
}

extension String {
    package var feeqdTrimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
