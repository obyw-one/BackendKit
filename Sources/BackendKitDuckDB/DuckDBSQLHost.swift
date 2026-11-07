#if BACKENDKIT_DUCKDB
import BackendKitSQL
import DuckDB
import Foundation
import Logging
import NIOCore
import NIOPosix
import SQLKit

// MARK: - DuckDBSQLHost

//
// The DuckDB engine for `SQLRepository` (spec b4f8c3a1 W3, BR-SQL-08). There is no official
// SQLKit driver for DuckDB, so this target IS the driver: `DuckDBSQLDatabase` conforms to
// `SQLDatabase`, lowers SQLKit's expression tree to text + binds, and runs it through
// duckdb-swift prepared statements on ONE actor (DuckDB is single-writer, in-process).
// Shaped like `SQLiteSQLHost`: `open(storage:) async throws`, `database`, `shutdown()`.
// DuckDB is confined to this target; BackendKitCore never sees it.

public final class DuckDBSQLHost: Sendable {
    /// Where the database lives.
    public enum Storage: Sendable {
        /// A private in-memory database, gone at `shutdown()`.
        case memory
        /// A file database at `path` (created if absent).
        case file(path: String)
    }

    private let engine: DuckDBEngine

    /// The injected engine: hand this to `SQLRepository`.
    public let database: any SQLDatabase

    private init(engine: DuckDBEngine, logger: Logger) {
        self.engine = engine
        database = DuckDBSQLDatabase(engine: engine, logger: logger)
    }

    /// Open the database. Async so the (possibly slow) open never blocks the caller's executor.
    public static func open(
        storage: Storage = .memory,
        logger: Logger = Logger(label: "backendkit.duckdb.sql")
    ) async throws -> DuckDBSQLHost {
        let engine = try await Task.detached { try DuckDBEngine(storage: storage) }.value
        return DuckDBSQLHost(engine: engine, logger: logger)
    }

    /// Stop accepting statements. The C handles are released when the host is dropped.
    public func shutdown() async throws {
        await engine.close()
    }
}

// MARK: - DuckDBSQLDatabase

struct DuckDBSQLDatabase: SQLDatabase {
    let engine: DuckDBEngine
    let logger: Logger

    var eventLoop: any EventLoop { MultiThreadedEventLoopGroup.singleton.next() }
    var dialect: any SQLDialect { DuckDBDialect() }

    func execute(
        sql query: any SQLExpression,
        _ onRow: @escaping @Sendable (any SQLRow) -> Void
    ) -> EventLoopFuture<Void> {
        let promise = eventLoop.makePromise(of: Void.self)
        Task {
            do {
                try await self.execute(sql: query, onRow)
                promise.succeed(())
            } catch {
                promise.fail(error)
            }
        }
        return promise.futureResult
    }

    func execute(
        sql query: any SQLExpression,
        _ onRow: @escaping @Sendable (any SQLRow) -> Void
    ) async throws {
        let (sql, rawBinds) = serialize(query)
        if let level = queryLogLevel {
            logger.log(level: level, "Executing query", metadata: ["sql": .string(sql), "binds": .array(rawBinds.map { .string("\($0)") })])
        }
        let binds = try rawBinds.map { try DuckDBBindEncoder.encode($0) }
        for row in try await engine.run(sql: sql, binds: binds) {
            onRow(row)
        }
    }
}
#endif
