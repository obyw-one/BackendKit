// swift-tools-version: 6.1
// BackendKit — the engine-agnostic database connection seam and one product per
// engine, on CoreKit's repository abstraction (spec b7e2d4f6, 2026-09-12).
// Dependency direction: BackendKit → CoreKit only — never NetKit, never ShiKit.
import PackageDescription

// MARK: - Platform split
//
// `platforms:` below declares Apple MINIMUMS only; SwiftPM cannot exclude a platform from a single target.
// What each product is available on is therefore declared HERE, once. Every product is offered everywhere
// EXCEPT DuckDB on Linux: its engine dependency carries `condition: .when(platforms: duckDBPlatforms)` and the same
// list defines a compilation flag (`BACKENDKIT_DUCKDB`) that wraps the target's sources. Off its platforms the
// target is an empty module: importing it works, USING one of its types is a compile error (the DuckDB types carry
// an `unavailable` stub that says why), never a runtime surprise.
//
//   BackendKitCore, BackendKitSQL, BackendKitSQLite   macOS, iOS, tvOS, Linux
//   BackendKitPostgres (PostgresNIO, PostgresKit)     macOS, iOS, tvOS, Linux
//   BackendKitDuckDB   (duckdb-swift)                 macOS, iOS, tvOS — NOT Linux, see below
//
// Postgres on iOS and tvOS was measured, not assumed (2026-11-07): the live Codable round-trip
// (`PostgresRepository`, over `PostgresClientHost`) and the live SQLRepository round-trip (over `PostgresSQLHost`)
// connected to a real Postgres 17 (SCRAM auth), wrote and read back on an iOS 26.5 Simulator and a tvOS 26.5
// Simulator through `xcodebuild test`, and the server's own log shows the statements. A Simulator is not a device
// (it shares the Mac's network stack and permissions), so a run on hardware is still the consumer's to confirm.
//
// DuckDB is not offered on Linux because duckdb-swift does not compile there. Measured 2026-11-07 on
// swift:6.3-jammy (arm64): `Sources/DuckDB/Internal/CTypeUtilities.swift:283-287` and
// `Extensions/Decimal+IntHuge.swift:42,64` build and read Foundation.Decimal through its `_mantissa` / `_length`
// members, which Linux's Foundation does not expose ("'_mantissa' is inaccessible due to 'internal' protection
// level"). The pinned 2.1.0-dev84836 is also upstream `main`, so there is no newer revision to move to, and the
// newest 1.x dev tag (1.6.0-dev11145) and the newest 1.x stable (1.1.3) fail with the same errors. This is
// upstream's to fix; BackendKit does not fork, vendor or patch duckdb-swift. Re-add `.linux` to this list when a
// duckdb-swift revision builds there (the Linux job in .woodpecker/linux-build.yml will then be the proof).
let duckDBPlatforms: [Platform] = [.macOS, .iOS, .tvOS]

let package = Package(
    name: "BackendKit",
    // `platforms:` declares APPLE minimums only; it does not exclude Linux/Windows, nor a platform per target — which
    // products exist where is the "Platform split" above.
    // (CoreKit 0.12.0's core is Linux-clean: SwiftUI lives in the Apple-only CoreKitUI product, which BackendKit never imports.)
    // Floors follow CoreKit 0.12.0 (iOS 17 / macOS 14 / tvOS 18); every engine dependency declares lower floors.
    platforms: [.macOS(.v14), .iOS(.v17), .tvOS(.v18)],
    products: [
        .library(name: "BackendKitCore", targets: ["BackendKitCore"]),
        // Every platform (see "Platform split"): measured live on macOS, iOS and tvOS Simulators and on Linux.
        .library(name: "BackendKitPostgres", targets: ["BackendKitPostgres"]),
        // Engine-neutral (SQLKit only, no driver), so it is on every platform the SQLite engine is. BR-SQL-03 stands in
        // its original sense: NetKit's wire layer never imports it. What is server-side is the Postgres ENGINE, not this.
        .library(name: "BackendKitSQL", targets: ["BackendKitSQL"]),
        // SQLite engine for SQLRepository (spec b4f8c3a1 W2) — official sqlite-kit, file + in-memory.
        .library(name: "BackendKitSQLite", targets: ["BackendKitSQLite"]),
        // DuckDB engine for SQLRepository (spec b4f8c3a1 W3) — custom SQLKit driver over duckdb-swift; embedded, single-writer.
        // macOS, iOS and tvOS only: duckdb-swift does not compile on Linux (see `duckDBPlatforms`).
        .library(name: "BackendKitDuckDB", targets: ["BackendKitDuckDB"]),
    ],
    dependencies: [
        // TypedEnvironment (the one env reader) + CoreKitTestSupport.TestScratch / TestPackagePaths
        .package(url: "https://github.com/obyw-one/CoreKit.git", from: "0.12.0"),
        .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.30.1"),
        // Latest stable by design (BR-SQL-06, operator 2026-11-04) — SQLKit + PostgresKit need tools 6.1.
        .package(url: "https://github.com/vapor/sql-kit.git", from: "3.36.0"),
        .package(url: "https://github.com/vapor/postgres-kit.git", from: "2.17.0"),
        .package(url: "https://github.com/vapor/sqlite-kit.git", from: "4.5.2"),
        // duckdb-swift has NO stable 2.x tag yet: pinned to a DuckDB-2.x DEV SNAPSHOT (exact; `from:` cannot range over dev tags).
        // Move to `from: "2.x.y"` once a stable 2.x binding tag ships.
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
        .target(
            name: "BackendKitDuckDB",
            dependencies: [
                "BackendKitSQL",
                .product(name: "DuckDB", package: "duckdb-swift", condition: .when(platforms: duckDBPlatforms)),
                .product(name: "SQLKit", package: "sql-kit"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: [.define("BACKENDKIT_DUCKDB", .when(platforms: duckDBPlatforms))]
        ),
        .testTarget(
            name: "BackendKitDuckDBTests",
            dependencies: [
                "BackendKitSQL",
                "BackendKitDuckDB",
                .product(name: "SQLKitBenchmark", package: "sql-kit"),
                .product(name: "CoreKitTestSupport", package: "CoreKit"),
            ],
            swiftSettings: [.define("BACKENDKIT_DUCKDB", .when(platforms: duckDBPlatforms))]
        ),
        .testTarget(
            name: "BackendKitSQLiteTests",
            dependencies: [
                "BackendKitSQL",
                "BackendKitSQLite",
                .product(name: "SQLKitBenchmark", package: "sql-kit"),
                // Container / DIAssembly / @Resolve / TaskDeadline for the engine-swap and sleep tests.
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
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
    ]
)
