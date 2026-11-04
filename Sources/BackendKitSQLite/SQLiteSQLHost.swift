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
        /// An existing file database opened read-only (SQLite URI `mode=ro`): writes are refused by
        /// the engine, and a missing file is an error rather than a freshly created empty database.
        case readOnlyFile(path: String)
    }

    /// The journal mode a file database is switched to right after opening.
    public enum JournalMode: String, Sendable {
        /// Write-ahead log: readers do not block the writer.
        case wal = "WAL"
    }

    private let connection: SQLiteConnection
    private let lifecycle = Lifecycle()

    /// Whether `shutdown()` (or the deinit close) has already taken the connection.
    private final class Lifecycle: @unchecked Sendable {
        private let lock = NSLock()
        private var closing = false
        /// `true` for the first caller only: that caller owns the close.
        func claimClose() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if closing { return false }
            closing = true
            return true
        }
    }

    /// The injected engine: hand this to `SQLRepository`.
    public let database: any SQLDatabase

    private init(connection: SQLiteConnection, logger: Logger) {
        self.connection = connection
        database = connection.sql()
    }

    /// Open the database. Async because the open runs on SQLiteNIO's thread pool.
    public static func open(
        storage: Storage = .memory,
        journalMode: JournalMode? = nil,
        logger: Logger = Logger(label: "backendkit.sqlite.sql")
    ) async throws -> SQLiteSQLHost {
        let sqliteStorage: SQLiteConnection.Storage = switch storage {
        case .memory: .memory
        case .file(let path): .file(path: path)
        case .readOnlyFile(let path): .file(path: Self.readOnlyURI(path: path))
        }
        let connection = try await SQLiteConnection.open(storage: sqliteStorage, logger: logger)
        if let journalMode {
            // The engine's own pragma, issued here so no consumer writes a SQL string for it.
            do {
                _ = try await connection.query("PRAGMA journal_mode=\(journalMode.rawValue)")
            } catch {
                try? await connection.close()
                throw error
            }
        }
        return SQLiteSQLHost(connection: connection, logger: logger)
    }

    /// `CREATE INDEX` that is a no-op when the index already exists. SQLKit's index builder has no
    /// `IF NOT EXISTS` (its dialects disagree on it), so the check reads SQLite's own catalogue.
    public func createIndexIfNotExists(_ name: String, on table: String, columns: [String]) async throws {
        let existing = try await database.select()
            .column("name")
            .from("sqlite_master")
            .where("type", .equal, "index")
            .where("name", .equal, name)
            .first()
        guard existing == nil else { return }
        let builder = database.create(index: name).on(table)
        for column in columns {
            _ = builder.column(column)
        }
        try await builder.run()
    }

    /// `true` when `error` is SQLite refusing a write for a constraint (UNIQUE, PRIMARY KEY,
    /// NOT NULL, CHECK, FOREIGN KEY): the one engine-specific fact a store needs to turn a
    /// duplicate insert into its own domain error.
    public static func isConstraintViolation(_ error: any Error) -> Bool {
        guard let sqlite = error as? SQLiteError else { return false }
        switch sqlite.reason {
        case .constraint, .constraintCheckFailed, .constraintForeignKeyFailed, .constraintNotNullFailed,
             .constraintPrimaryKeyFailed, .constraintUniqueFailed, .constraintUniqueRowIDFailed:
            return true
        default:
            return false
        }
    }

    private static func readOnlyURI(path: String) -> String {
        var components = URLComponents()
        components.scheme = "file"
        components.path = path
        components.queryItems = [URLQueryItem(name: "mode", value: "ro")]
        return components.string ?? path
    }

    /// Close the connection. Call once, before the host is dropped.
    public func shutdown() async throws {
        guard lifecycle.claimClose() else { return }
        try await connection.close()
    }

    /// A host dropped without `shutdown()` still closes its connection: SQLiteNIO asserts
    /// (debug builds) that a connection is closed before it deinitialises, and a consumer's
    /// store is an object whose lifetime ends by being released, not by an awaited call.
    /// The detached close keeps the connection alive until it completes.
    deinit {
        guard lifecycle.claimClose() else { return }
        let connection = connection
        Task.detached { try? await connection.close() }
    }
}
