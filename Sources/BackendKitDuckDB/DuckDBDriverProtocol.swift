import Foundation

// MARK: - DuckDBDriverProtocol

//
// The facade in front of DuckDB. BackendKitDuckDB runs on two DuckDB bindings that are not the same code:
// duckdb-swift on Apple platforms (`DuckDBSwiftDriver`) and the official `libduckdb` through its C API on Linux
// (`DuckDBCAPIDriver`), because duckdb-swift does not compile on Linux (see Package.swift). Everything above this
// protocol is ONE implementation: the engine actor, the host, the bind encoder, the value decoder, the dialect.
// A driver does exactly three things: open a database, run one statement with bound values and hand back the
// rows as `DuckDBValue` cells, and close. It owns raw handles, so it is deliberately NOT `Sendable`: the one
// `DuckDBEngine` actor owns it and is the only thing that ever touches it, which is what makes that honest.
//
// The contract both drivers keep (and `DuckDBBehaviourTests` runs, unchanged, against whichever one is compiled):
//   - every failure DuckDB reports is thrown as `DuckDBSQLError.engine(<DuckDB's own text>)`;
//   - a result column of a type the cell vocabulary cannot carry throws `unsupportedColumnType`, never NULL;
//   - NULL is `.null` and nothing else is;
//   - all native resources are released on every path, and `close()` releases them at once (a file database is
//     reopenable immediately afterwards).

protocol DuckDBDriverProtocol: AnyObject {
    /// The DuckDB version this driver is pinned to, as `SELECT version()` reports it. See `DuckDBVersionPins`.
    static var pinnedLibraryVersion: String { get }

    init(storage: DuckDBSQLHost.Storage) throws

    /// Run ONE statement with bound parameters and return its rows (a statement that returns none gives `[]`).
    func run(sql: String, binds: [DuckDBValue]) throws -> [DuckDBSQLRow]

    /// Release the database and connection now. Idempotent; `run` throws `shutDown` afterwards.
    func close()
}

// MARK: - Compile-time selection (the one place the platform split is decided)

// By operating system, matching the two conditional dependencies in Package.swift. Not by `canImport`: a stale
// module left in a reused build directory makes `canImport(DuckDB)` true on Linux, where it must never be used.
#if os(Linux)
typealias DuckDBPlatformDriver = DuckDBCAPIDriver
#elseif os(macOS) || os(iOS) || os(tvOS)
typealias DuckDBPlatformDriver = DuckDBSwiftDriver
#else
#error("BackendKitDuckDB supports macOS, iOS and tvOS (duckdb-swift) and Linux (libduckdb through CDuckDB).")
#endif

// MARK: - DuckDBVersionPins

/// The DuckDB versions this package is built and tested against, in ONE place. The two sides are on different
/// versions because duckdb-swift has no stable release for DuckDB 2.x and does not build on Linux, while the
/// official libduckdb is released as stable on Linux. A bump is deliberate on both sides: `Package.swift`'s exact
/// duckdb-swift tag and `Scripts/libduckdb.lock` must agree with these constants (`DuckDBVersionPinTests` fails
/// otherwise), and the same test fails when the library actually loaded reports a different version.
enum DuckDBVersionPins {
    /// Apple platforms: the exact duckdb-swift tag `Package.swift` pins.
    static let appleSwiftBindingTag = "2.1.0-dev84836"
    /// Apple platforms: what `SELECT version()` reports for that tag's bundled DuckDB.
    static let appleLibraryVersion = "v2.1.0-dev84836"
    /// Linux: the official libduckdb release `Scripts/libduckdb.lock` installs; `SELECT version()` reports the same.
    static let linuxLibraryVersion = "v2.0.0"
}
