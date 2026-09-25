// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LokiKitConsumer",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "ConsumerHarness", targets: ["ConsumerHarness"])],
    dependencies: [
        .package(url: "https://github.com/LeePepe/shared-telemetry.git", revision: "55b3e1441fac2d1caef51b0af9478c59ad6c334c")
    ],
    targets: [
        .target(name: "ConsumerHarness", dependencies: [
            .product(name: "LokiKit", package: "shared-telemetry")
        ]),
        .testTarget(name: "ConsumerTests", dependencies: [
            "ConsumerHarness", .product(name: "LokiKit", package: "shared-telemetry")
        ])
    ]
)
