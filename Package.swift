// swift-tools-version: 6.1
// Dependency direction: BackendKit → CoreKit only, never NetKit, never ShiKit. Docs: docs/ (see README.md).
import PackageDescription

let duckDBSwiftPlatforms: [Platform] = [.macOS, .iOS, .tvOS, .visionOS]
let libDuckDBPlatforms: [Platform] = [.linux]

// CDuckDB exists only when the manifest is evaluated on Linux (docs/duckdb.md).
var duckDBLinuxDependencies: [Target.Dependency] = []
var duckDBLinuxTargets: [Target] = []
#if os(Linux)
duckDBLinuxDependencies = [.target(name: "CDuckDB", condition: .when(platforms: libDuckDBPlatforms))]
duckDBLinuxTargets = [.systemLibrary(name: "CDuckDB", pkgConfig: "duckdb")]
#endif

let package = Package(
    name: "BackendKit",
    platforms: [.macOS(.v14), .iOS(.v17), .tvOS(.v18), .visionOS(.v1)],
    products: [
        .library(name: "BackendKitCore", targets: ["BackendKitCore"]),
        .library(name: "BackendKitPostgres", targets: ["BackendKitPostgres"]),
        .library(name: "BackendKitSQL", targets: ["BackendKitSQL"]),
        .library(name: "BackendKitSQLite", targets: ["BackendKitSQLite"]),
        .library(name: "BackendKitDuckDB", targets: ["BackendKitDuckDB"]),
    ],
    dependencies: [
        .package(url: "https://github.com/obyw-one/CoreKit.git", from: "0.13.0"),
        .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.30.1"),
        .package(url: "https://github.com/vapor/sql-kit.git", from: "3.36.0"),
        .package(url: "https://github.com/vapor/postgres-kit.git", from: "2.17.0"),
        .package(url: "https://github.com/vapor/sqlite-kit.git", from: "4.5.2"),
        // Exact dev snapshot, no stable 2.x tag exists; must equal DuckDBVersionPins (docs/duckdb.md).
        .package(url: "https://github.com/duckdb/duckdb-swift.git", exact: "2.1.0-dev84836"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
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
        .target(
            name: "BackendKitTestSupport",
            dependencies: [
                "BackendKitCore",
                .product(name: "CoreKit", package: "CoreKit"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
            ]
        ),
        .target(
            name: "BackendKitDuckDB",
            dependencies: [
                "BackendKitSQL",
                .product(name: "DuckDB", package: "duckdb-swift", condition: .when(platforms: duckDBSwiftPlatforms)),
                .product(name: "SQLKit", package: "sql-kit"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
            ] + duckDBLinuxDependencies
        ),
        .testTarget(
            name: "BackendKitDuckDBTests",
            dependencies: [
                "BackendKitSQL",
                "BackendKitDuckDB",
                .product(name: "SQLKitBenchmark", package: "sql-kit"),
                .product(name: "CoreKitTestSupport", package: "CoreKit"),
            ]
        ),
        .testTarget(
            name: "BackendKitSQLiteTests",
            dependencies: [
                "BackendKitTestSupport",
                "BackendKitSQL",
                "BackendKitSQLite",
                .product(name: "SQLKitBenchmark", package: "sql-kit"),
                .product(name: "CoreKit", package: "CoreKit"),
                .product(name: "CoreKitTestSupport", package: "CoreKit"),
                .product(name: "Logging", package: "swift-log"),
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
                "BackendKitTestSupport",
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                "BackendKitSQL",
                "BackendKitPostgres",
                .product(name: "SQLKitBenchmark", package: "sql-kit"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "CoreKitTestSupport", package: "CoreKit"),
            ]
        ),
        .testTarget(
            name: "BackendKitGateTests",
            dependencies: [
                .product(name: "CoreKitTestSupport", package: "CoreKit"),
            ]
        ),
        .testTarget(
            name: "BackendKitPostgresTests",
            dependencies: [
                "BackendKitTestSupport",
                "BackendKitPostgres",
                .product(name: "CoreKit", package: "CoreKit"),
                .product(name: "CoreKitTestSupport", package: "CoreKit"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
    ] + duckDBLinuxTargets
)
