import BackendKitDuckDB
import BackendKitMigrations
import BackendKitPostgres
import BackendKitSQL
import BackendKitSQLite
import BackendKitTestSupport
import Foundation
import SQLKit

// MARK: - ResourceEngine

/// The three engines the resource layer runs on. SQLite and DuckDB are embedded and always run;
/// Postgres needs a live server (`BACKENDKIT_LIVE_TESTS=1` + the libpq variables) and runs only then.
enum ResourceEngine: String, CaseIterable, Sendable, CustomStringConvertible {
    case sqlite
    case duckdb
    case postgres

    var description: String { rawValue }

    /// The engines this run can reach: the embedded ones always, Postgres only against a live server.
    static var available: [ResourceEngine] {
        LiveDatabase().isLive ? allCases : allCases.filter { $0 != .postgres }
    }

    /// Opens the engine and creates one cache table and one configuration table under unique names.
    func open() async throws -> ResourceSession {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        let cacheTable = "bk_cache_\(suffix)"
        let configTable = "bk_config_\(suffix)"
        switch self {
        case .sqlite:
            let host = try await SQLiteSQLHost.open(storage: .memory)
            try await host.createStrictTable(cacheTable, SQLCacheBackingSchema.configure)
            try await host.createStrictTable(configTable, SQLConfigSchema.configure)
            return ResourceSession(
                engine: self, database: host.database, cacheTable: cacheTable, configTable: configTable,
                createLedger: { try await host.createStrictTable($0.tableName, SQLMigrationLedger.configure) },
                close: { try await host.shutdown() })
        case .duckdb:
            let host = try await DuckDBSQLHost.open(storage: .memory)
            try await SQLCacheBackingSchema.create(on: host.database, table: cacheTable)
            try await SQLConfigSchema.create(on: host.database, table: configTable)
            return ResourceSession(
                engine: self, database: host.database, cacheTable: cacheTable, configTable: configTable,
                createLedger: { [database = host.database] in try await SQLMigrationLedger.create(on: database, contract: $0) },
                close: { try await host.shutdown() })
        case .postgres:
            let host = PostgresSQLHost(connection: LiveDatabase().connection())
            do {
                try await SQLCacheBackingSchema.create(on: host.database, table: cacheTable)
                try await SQLConfigSchema.create(on: host.database, table: configTable)
            } catch {
                throw await SessionError.afterClosing({ try await host.shutdown() }, failure: error)
            }
            return ResourceSession(
                engine: self, database: host.database, cacheTable: cacheTable, configTable: configTable,
                createLedger: { [database = host.database] in try await SQLMigrationLedger.create(on: database, contract: $0) },
                close: {
                    // Drop what this session made, then close: a live server is shared, so leave nothing behind.
                    try await host.database.drop(table: cacheTable).ifExists().run()
                    try await host.database.drop(table: configTable).ifExists().run()
                    try await host.shutdown()
                })
        }
    }
}

// MARK: - ResourceSession

/// One opened engine with its two tables, and the close that releases it.
struct ResourceSession: Sendable {
    let engine: ResourceEngine
    let database: any SQLDatabase
    let cacheTable: String
    let configTable: String
    /// Creates a migration ledger the way this engine's consumer does: STRICT on SQLite, `IF NOT EXISTS` elsewhere.
    let createLedger: @Sendable (MigrationLedgerContract) async throws -> Void
    let close: @Sendable () async throws -> Void

    /// Drops tables this session made (a live server is shared).
    func dropAll(_ tables: [String]) async throws {
        for table in tables { try await database.drop(table: table).ifExists().run() }
    }

    /// Runs `body`, then closes the session; a failure of `body` wins over a failure of the close.
    func use<Result: Sendable>(_ body: @Sendable (ResourceSession) async throws -> Result) async throws -> Result {
        let result: Result
        do {
            result = try await body(self)
        } catch {
            throw await SessionError.afterClosing(close, failure: error)
        }
        try await close()
        return result
    }
}

enum SessionError: Error, CustomStringConvertible {
    case bodyAndCloseFailed(body: String, close: String)

    /// Runs `close`, then returns the error to throw: `failure` itself, or both causes when the close failed too.
    static func afterClosing(_ close: @Sendable () async throws -> Void, failure: any Error) async -> any Error {
        do {
            try await close()
            return failure
        } catch {
            return bodyAndCloseFailed(body: "\(failure)", close: "\(error)")
        }
    }

    var description: String {
        switch self {
        case .bodyAndCloseFailed(let body, let close): "\(body) (and closing the session failed too: \(close))"
        }
    }
}
