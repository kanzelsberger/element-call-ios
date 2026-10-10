// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "ElementCall",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "ElementCallKit", targets: ["ElementCallKit"]),
        .library(name: "ElementCallMatrix", targets: ["ElementCallMatrix"])
    ],
    dependencies: [
        .package(url: "https://github.com/element-hq/matrix-rust-rtc", exact: "0.4.0-rc.1"),
        .package(url: "https://github.com/kanzelsberger/matrix-rust-components-swift.git", exact: "26.10.9-mango.1")
    ],
    targets: [
        .target(name: "ElementCallKit",
                dependencies: [.product(name: "MatrixRtc", package: "matrix-rust-rtc")],
                swiftSettings: [.defaultIsolation(MainActor.self)]),
        .target(name: "ElementCallHost",
                path: "Sources/ElementCallHost/Ports",
                exclude: ["ElementCallFakes.swift", "ElementCallOptions.swift", "ElementCallRoomContext.swift", "ElementCallStyle.swift", "ElementCallSystemProviding.swift", "ElementCallTokenStyle.swift"],
                sources: ["ElementCallLogging.swift"],
                swiftSettings: [.defaultIsolation(MainActor.self)]),
        .target(name: "ElementCallMatrix",
                dependencies: ["ElementCallKit", "ElementCallHost", .product(name: "MatrixRustSDK", package: "matrix-rust-components-swift")],
                swiftSettings: [.defaultIsolation(MainActor.self)]),
        .testTarget(name: "ElementCallTests",
                    dependencies: ["ElementCallMatrix"],
                    sources: ["JoinedMembershipTests.swift"],
                    swiftSettings: [.defaultIsolation(MainActor.self)])
    ]
)
