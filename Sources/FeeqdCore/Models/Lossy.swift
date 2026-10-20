import Foundation

/// Decodes a value or nothing, never an error.
///
/// Used for list elements and dictionary values: one malformed row must not take the whole
/// page down, and a value the server adds tomorrow must not break a build already on the
/// App Store.
package struct Lossy<Value: Decodable>: Decodable {
    package let value: Value?

    package init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

extension Lossy: Sendable where Value: Sendable {}
