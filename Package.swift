// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "CliBuddy",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "CliBuddy", targets: ["CliBuddy"])
    ],
    dependencies: [
        // Swift Testing ships with Swift 6 via full Xcode but is absent from
        // Command Line Tools toolchains; pull it as an SPM dependency so tests
        // compile under CLT. Safe to remove once CLT ships Testing by default.
        .package(url: "https://github.com/apple/swift-testing", from: "0.10.0")
    ],
    targets: [
        .executableTarget(
            name: "CliBuddy",
            path: "Sources/CliBuddy",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "CliBuddyTests",
            dependencies: [
                "CliBuddy",
                .product(name: "Testing", package: "swift-testing")
            ],
            path: "Tests/CliBuddyTests"
        )
    ]
)
