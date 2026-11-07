// swift-tools-version: 6.1
// BackendKit — the engine-agnostic database connection seam and one product per
// engine, on CoreKit's repository abstraction (spec b7e2d4f6, 2026-09-12).
// Dependency direction: BackendKit → CoreKit only — never NetKit, never ShiKit.
import PackageDescription

// MARK: - Platform split
//
// `platforms:` below declares Apple MINIMUMS only; SwiftPM cannot exclude a platform from a single target.
// Every product is offered on every platform: macOS, iOS, tvOS and Linux. BackendKit's public API is the same on all
// of them. What differs is what BackendKitDuckDB is built on, chosen once, here, per platform:
//
//   BackendKitCore, BackendKitSQL, BackendKitSQLite   macOS, iOS, tvOS, Linux
//   BackendKitPostgres (PostgresNIO, PostgresKit)     macOS, iOS, tvOS, Linux
//   BackendKitDuckDB                                  macOS, iOS, tvOS: duckdb-swift (DuckDB 2.1.0-dev84836)
//                                                     Linux: the official libduckdb 2.0.0 through its C API
//
// One facade (`DuckDBDriverProtocol`) sits in front of the two, so everything above it (the host, the bind encoder,
// the value decoder, the dialect) is one implementation, and one behaviour suite runs against whichever driver the
// platform compiles. Which driver is compiled is decided by the operating system (`#if os(Linux)` in the driver files), matching the
// two conditional dependencies below; there is no flag to keep in step.
//
// Why Linux does not use duckdb-swift: it does not compile there. Measured 2026-11-07 on swift:6.3-jammy (arm64):
// `Sources/DuckDB/Internal/CTypeUtilities.swift:283-287` and `Extensions/Decimal+IntHuge.swift:42,64` build and read
// Foundation.Decimal through its `_mantissa` / `_length` members, which Linux's Foundation does not expose ("'_mantissa'
// is inaccessible due to 'internal' protection level"). The pinned 2.1.0-dev84836 is upstream `main`, and the newest 1.x
// dev tag (1.6.0-dev11145) and the newest 1.x stable (1.1.3) fail with the same errors. BackendKit does not fork, vendor
// or patch duckdb-swift; Linux uses DuckDB's own C library instead.
//
// How Linux gets that library: `CDuckDB` is a system library found through pkg-config (`duckdb.pc`). It is NOT vendored
// and no binary is committed. `Scripts/install-libduckdb.sh` downloads the release pinned in `Scripts/libduckdb.lock`
// (exact version, per-architecture sha256, amd64 and arm64), refuses to continue on any mismatch, and installs
// `libduckdb.so`, `duckdb.h` and `duckdb.pc` under a prefix. The README ("DuckDB on Linux") has the build and the
// runtime steps. A consumer that does not use BackendKitDuckDB on Linux never needs the library: SwiftPM only builds
// the targets a product reaches.
//
// DuckDB versions: the two sides are NOT on the same DuckDB. duckdb-swift has no stable release for DuckDB 2.x (its
// newest tags are dev snapshots; the newest stable is 1.1.3), so Apple stays on the dev snapshot pinned below while
// Linux runs the stable 2.0.0 library. `DuckDBVersionPins` records both versions in one place, and
// `DuckDBVersionPinTests` fails if this file, `Scripts/libduckdb.lock` or the library that actually loads disagrees with
// it, so a bump is deliberate on both sides. Move Apple to a stable duckdb-swift tag as soon as one exists for DuckDB 2.x.
//
// Postgres on iOS and tvOS was measured, not assumed (2026-11-07): the live Codable round-trip
// (`PostgresRepository`, over `PostgresClientHost`) and the live SQLRepository round-trip (over `PostgresSQLHost`)
// connected to a real Postgres 17 (SCRAM auth), wrote and read back on an iOS 26.5 Simulator and a tvOS 26.5
// Simulator through `xcodebuild test`, and the server's own log shows the statements. A Simulator is not a device
// (it shares the Mac's network stack and permissions), so a run on hardware is still the consumer's to confirm.
let duckDBSwiftPlatforms: [Platform] = [.macOS, .iOS, .tvOS]
let libDuckDBPlatforms: [Platform] = [.linux]

// `CDuckDB` is declared only when the manifest itself is evaluated on Linux. SwiftPM resolves a system library's
// pkg-config file whether or not the build uses it, so declaring it on Apple hosts would print "couldn't find pc file
// for duckdb" on every macOS and Xcode build of every consumer, DuckDB or not. (Cross-compiling to Linux from a Mac
// is therefore not supported for BackendKitDuckDB; every other product cross-compiles as before.)
var duckDBLinuxDependencies: [Target.Dependency] = []
var duckDBLinuxTargets: [Target] = []
#if os(Linux)
duckDBLinuxDependencies = [.target(name: "CDuckDB", condition: .when(platforms: libDuckDBPlatforms))]
// The official libduckdb C API, resolved through pkg-config (`duckdb.pc`). No source of its own.
duckDBLinuxTargets = [.systemLibrary(name: "CDuckDB", pkgConfig: "duckdb")]
#endif

let package = Package(
    name: "BackendKit",
    // `platforms:` declares APPLE minimums only; it does not exclude Linux/Windows, nor a platform per target — which
    // products exist where is the "Platform split" above.
    // (CoreKit 0.13.0's core is Linux-clean: SwiftUI lives in the Apple-only CoreKitUI product, which BackendKit never imports.)
    // Floors follow CoreKit 0.13.0 (iOS 17 / macOS 14 / tvOS 18); every engine dependency declares lower floors.
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
        // DuckDB engine for SQLRepository (spec b4f8c3a1 W3) — custom SQLKit driver; embedded, single-writer. duckdb-swift on
        // Apple platforms, the official libduckdb C API on Linux, one facade in front (see "Platform split").
        .library(name: "BackendKitDuckDB", targets: ["BackendKitDuckDB"]),
    ],
    dependencies: [
        // TypedEnvironment (the one env reader) + CoreKitTestSupport.TestScratch / TestPackagePaths
        .package(url: "https://github.com/obyw-one/CoreKit.git", from: "0.13.0"),
        .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.30.1"),
        // Latest stable by design (BR-SQL-06, operator 2026-11-04) — SQLKit + PostgresKit need tools 6.1.
        .package(url: "https://github.com/vapor/sql-kit.git", from: "3.36.0"),
        .package(url: "https://github.com/vapor/postgres-kit.git", from: "2.17.0"),
        .package(url: "https://github.com/vapor/sqlite-kit.git", from: "4.5.2"),
        // Apple platforms only. duckdb-swift has NO stable 2.x tag (newest stable: 1.1.3, which is DuckDB 1.1): pinned to a
        // DuckDB-2.x DEV SNAPSHOT (exact; `from:` cannot range over dev tags), DuckDB 2.1.0-dev84836. Linux is on the stable
        // libduckdb 2.0.0 instead (see "Platform split"). Move to `from: "2.x.y"` once a stable 2.x binding tag ships.
        // `DuckDBVersionPins.appleSwiftBindingTag` must equal this tag; a test enforces it.
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
    ] + duckDBLinuxTargets
)
