// MARK: - Off macOS, iOS and tvOS

//
// BackendKitDuckDB links duckdb-swift, which does not compile on Linux (`duckDBPlatforms` in Package.swift names
// the upstream failure). Off its platforms the target compiles to this file alone, so `import BackendKitDuckDB`
// is accepted but the first USE of a DuckDB type is a compile error that says why. The attribute messages are
// literals on purpose.

#if !BACKENDKIT_DUCKDB

@available(*, unavailable, message: "BackendKitDuckDB is macOS, iOS and tvOS only: duckdb-swift does not build on Linux. Use BackendKitSQLite or BackendKitPostgres there.")
public final class DuckDBSQLHost {}

@available(*, unavailable, message: "BackendKitDuckDB is macOS, iOS and tvOS only: duckdb-swift does not build on Linux. Use BackendKitSQLite or BackendKitPostgres there.")
public struct DuckDBDialect {}

@available(*, unavailable, message: "BackendKitDuckDB is macOS, iOS and tvOS only: duckdb-swift does not build on Linux. Use BackendKitSQLite or BackendKitPostgres there.")
public enum DuckDBSQLError: Error {}

#endif
