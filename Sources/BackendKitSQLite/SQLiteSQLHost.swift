import BackendKitSQL
import Foundation
import Logging
import SQLiteKit
import SQLKit

// MARK: - SQLiteSQLHost

//
// The SQLite engine for `SQLRepository` (spec b4f8c3a1 W2, BR-SQL-04/07). Shaped like
// `PostgresSQLHost`: it owns the engine's resources and exposes `database: any SQLDatabase`;
// `shutdown()` is async. Backed by the official `sqlite-kit` (SQLiteNIO) — file and in-memory
// storage. SQLite is embedded, so there is no pool to size: the host owns ONE connection
// (SQLiteNIO serialises every call on its thread pool, which also keeps an in-memory
// database alive for the host's lifetime). No NIO group is owned: SQLiteNIO runs on NIO's
// process singletons, so nothing leaks past `shutdown()`.
//
// A libSQL-only feature (embedded replica / remote) is NOT needed by SQLRepository, so
// there is no custom libsql-swift driver here.

public final class SQLiteSQLHost: @unchecked Sendable {
    /// Where the database lives.
    public enum Storage: Sendable {
        /// A private in-memory database, gone at `shutdown()`.
        case memory
        /// A file database at `path` (created if absent).
        case file(path: String)
    }

    private let connection: SQLiteConnection

    /// The injected engine: hand this to `SQLRepository`.
    public let database: any SQLDatabase

    private init(connection: SQLiteConnection, logger: Logger) {
        self.connection = connection
        database = connection.sql()
    }

    /// Open the database. Async because the open runs on SQLiteNIO's thread pool.
    public static func open(
        storage: Storage = .memory,
        logger: Logger = Logger(label: "backendkit.sqlite.sql")
    ) async throws -> SQLiteSQLHost {
        let sqliteStorage: SQLiteConnection.Storage = switch storage {
        case .memory: .memory
        case .file(let path): .file(path: path)
        }
        let connection = try await SQLiteConnection.open(storage: sqliteStorage, logger: logger)
        return SQLiteSQLHost(connection: connection, logger: logger)
    }

    /// Close the connection. Call once, before the host is dropped.
    public func shutdown() async throws {
        try await connection.close()
    }
}
