// swift-tools-version: 6.0
import PackageDescription

// Three targets, one product.
//
// - FeeqdCore: networking, identity, models, stores. No SwiftUI, so its tests run on a Mac
//   in seconds without a simulator.
// - FeeqdUI: the screens.
// - FeeqdKit: the public facade (`Feeqd.configure`, `Feeqd.FeedbackView`). The only product.
//
// Cross-target APIs use the `package` access level: visible to the other targets of this
// package, invisible to the app that integrates it. Everything public is a compatibility
// promise, so only FeeqdKit declares `public` symbols.
let package = Package(
    name: "FeeqdKit",
    defaultLocalization: "en",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "FeeqdKit", targets: ["FeeqdKit"]),
    ],
    targets: [
        .target(name: "FeeqdCore", path: "Sources/FeeqdCore"),
        .target(name: "FeeqdUI", dependencies: ["FeeqdCore"], path: "Sources/FeeqdUI"),
        .target(
            name: "FeeqdKit",
            dependencies: ["FeeqdCore", "FeeqdUI"],
            path: "Sources/FeeqdKit",
            resources: [.copy("PrivacyInfo.xcprivacy")]
        ),
        .testTarget(
            name: "FeeqdCoreTests",
            dependencies: ["FeeqdCore"],
            path: "Tests/FeeqdCoreTests",
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "FeeqdUITests",
            dependencies: ["FeeqdCore", "FeeqdUI"],
            path: "Tests/FeeqdUITests"
        ),
    ],
    // Swift 6 checks data races at compile time; the package builds clean under it, and the
    // mode keeps it that way.
    swiftLanguageModes: [.v6]
)
