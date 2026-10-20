import Foundation

package struct RGBA: Equatable, Sendable {
    package let red: Double
    package let green: Double
    package let blue: Double
    package let alpha: Double

    package init(red: Double, green: Double, blue: Double, alpha: Double) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }
}

/// `#RGB`, `#RRGGBB` and `#RRGGBBAA`. Kept out of SwiftUI so it can be tested without a host.
package enum HexColor {
    package static func parse(_ hex: String) -> RGBA? {
        var digits = hex.feeqdTrimmed
        if digits.hasPrefix("#") { digits.removeFirst() }
        if digits.count == 3 { digits = digits.map { "\($0)\($0)" }.joined() }
        guard digits.count == 6 || digits.count == 8, let value = UInt64(digits, radix: 16) else { return nil }
        let hasAlpha = digits.count == 8
        let shift: UInt64 = hasAlpha ? 8 : 0
        func channel(_ offset: UInt64) -> Double { Double((value >> (offset + shift)) & 0xff) / 255 }
        return RGBA(
            red: channel(16),
            green: channel(8),
            blue: channel(0),
            alpha: hasAlpha ? Double(value & 0xff) / 255 : 1
        )
    }
}
