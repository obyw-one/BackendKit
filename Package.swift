// swift-tools-version: 6.0
// BackendKit — the engine-agnostic database connection seam and one product per
// engine, on CoreKit's repository abstraction (spec b7e2d4f6, 2026-09-12).
// Dependency direction: BackendKit → CoreKit only — never NetKit, never ShiKit.
// `BackendKitDuckDB` is reserved (no target until a consumer exists).
import PackageDescription

let package = Package(
    name: "BackendKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BackendKitCore", targets: ["BackendKitCore"]),
        .library(name: "BackendKitPostgres", targets: ["BackendKitPostgres"]),
    ],
    dependencies: [
        // CoreKit 0.17.0, from obyw-one — NOT FJ-Studios/CoreKit 0.9.1, which this
        // package pinned until 2026-11-15: the OLD org and eight minors back.
        // 0.9.1 gave TypedEnvironment and CoreKitTestSupport; 0.17.0 adds the
        // resource layer (0.14.0), CoreKitSecurity (0.15.0) and EventBusProviding
        // (0.17.0), and — the reason this bump belongs to spec c8fa126c — it is
        // the first CoreKit that cross-builds for Linux. Re-measured 2026-11-15
        // with the Static Linux SDK: `CoreKit` exits 0 for both
        // aarch64-swift-linux-musl and x86_64-swift-linux-musl, because the
        // SwiftUI/Combine/Network surface moved to the Apple-only CoreKitUI
        // product and the one `import os` is guarded.
        .package(url: "https://github.com/obyw-one/CoreKit.git", from: "0.17.0"),
        .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.22.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "BackendKitCore",
            dependencies: [
                .product(name: "CoreKit", package: "CoreKit"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .target(
            name: "BackendKitPostgres",
            dependencies: [
                "BackendKitCore",
                .product(name: "PostgresNIO", package: "postgres-nio"),
            ]
        ),
        .testTarget(
            name: "BackendKitCoreTests",
            dependencies: [
                "BackendKitCore",
                .product(name: "CoreKitTestSupport", package: "CoreKit"),
            ]
        ),
        .testTarget(
            name: "BackendKitPostgresTests",
            dependencies: [
                "BackendKitPostgres",
                .product(name: "CoreKitTestSupport", package: "CoreKit"),
            ]
        ),
    ]
)
