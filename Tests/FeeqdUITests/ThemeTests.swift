import FeeqdCore
@testable import FeeqdUI
import SwiftUI
import XCTest

final class ThemeTests: XCTestCase {
    private let planned = RemoteStatus(slug: "planned", label: "Planned", category: .open, position: 0, color: nil)
    private let shipped = RemoteStatus(
        slug: "shipped", label: "Shipped", category: .closed, position: 1, color: ColorPair(light: "#00AA00", dark: "#00AA00")
    )

    func testCodeColoursWinPerStatusThenPerStageThenTheDashboard() {
        let theme = ResolvedTheme(
            config: .fallback,
            overrides: ThemeOverrides(statusColors: ["planned": .purple], categoryColors: [.open: .orange, .closed: .pink])
        )
        XCTAssertEqual(theme.color(for: planned, slug: "planned"), .purple)
        XCTAssertEqual(theme.color(for: shipped, slug: "shipped"), .pink)

        let dashboardOnly = ResolvedTheme(config: .fallback, overrides: ThemeOverrides())
        XCTAssertNotEqual(dashboardOnly.color(for: shipped, slug: "shipped"), .secondary)
        XCTAssertEqual(dashboardOnly.color(for: planned, slug: "planned"), .secondary)
        // A status the board does not describe still takes a colour set for its slug.
        XCTAssertEqual(theme.color(for: nil, slug: "planned"), .purple)
    }
}
