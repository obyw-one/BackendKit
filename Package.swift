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
        .package(url: "https://github.com/FJ-Studios/CoreKit.git", from: "0.8.0"),
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
        .testTarget(name: "BackendKitCoreTests", dependencies: ["BackendKitCore"]),
        .testTarget(name: "BackendKitPostgresTests", dependencies: ["BackendKitPostgres"]),
    ]
)
