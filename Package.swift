// swift-tools-version: 6.1
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
        // Server-side only (BR-SQL-03): NetKit and the iOS client never import it.
        .library(name: "BackendKitSQL", targets: ["BackendKitSQL"]),
        // SQLite engine for SQLRepository (spec b4f8c3a1 W2) — official sqlite-kit, file + in-memory.
        .library(name: "BackendKitSQLite", targets: ["BackendKitSQLite"]),
    ],
    dependencies: [
        // 0.9.1: TypedEnvironment (the one env reader) + CoreKitTestSupport.TestScratch / TestPackagePaths
        .package(url: "https://github.com/FJ-Studios/CoreKit.git", from: "0.9.1"),
        .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.30.1"),
        // Latest stable by design (BR-SQL-06, operator 2026-11-04) — SQLKit + PostgresKit need tools 6.1.
        .package(url: "https://github.com/vapor/sql-kit.git", from: "3.36.0"),
        .package(url: "https://github.com/vapor/postgres-kit.git", from: "2.17.0"),
        .package(url: "https://github.com/vapor/sqlite-kit.git", from: "4.5.2"),
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
        // Typed, parameter-binding query layer (spec b4f8c3a1). SQLKit only — no driver.
        .target(
            name: "BackendKitSQL",
            dependencies: [
                .product(name: "CoreKit", package: "CoreKit"),
                .product(name: "SQLKit", package: "sql-kit"),
            ]
        ),
        .target(
            name: "BackendKitPostgres",
            dependencies: [
                "BackendKitCore",
                "BackendKitSQL",
                .product(name: "PostgresNIO", package: "postgres-nio"),
                .product(name: "PostgresKit", package: "postgres-kit"),
            ]
        ),
        .target(
            name: "BackendKitSQLite",
            dependencies: [
                "BackendKitSQL",
                .product(name: "SQLiteKit", package: "sqlite-kit"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .testTarget(
            name: "BackendKitSQLiteTests",
            dependencies: [
                "BackendKitSQL",
                "BackendKitSQLite",
                .product(name: "SQLKitBenchmark", package: "sql-kit"),
                .product(name: "CoreKitTestSupport", package: "CoreKit"),
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
            name: "BackendKitSQLTests",
            dependencies: [
                "BackendKitSQL",
                "BackendKitPostgres",
                .product(name: "SQLKitBenchmark", package: "sql-kit"),
                .product(name: "Logging", package: "swift-log"),
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
