import Foundation

// MARK: - DuckDBEngine

//
// The ONE actor that owns the DuckDB driver. DuckDB is in-process and single-writer, so every statement is
// serialised here; nothing else touches the native handles. The driver is not `Sendable` and does not need to be:
// it is created inside this actor's initialiser and never leaves it. Every value is BOUND through a prepared
// statement — SQL text never carries data. Platform differences stop at `DuckDBDriverProtocol`.

actor DuckDBEngine {
    private let driver: DuckDBPlatformDriver
    private var closed = false

    /// The DuckDB version the compiled driver is pinned to (`DuckDBVersionPins`).
    static var pinnedLibraryVersion: String { DuckDBPlatformDriver.pinnedLibraryVersion }

    init(storage: DuckDBSQLHost.Storage) throws {
        driver = try DuckDBPlatformDriver(storage: storage)
        do {
            _ = try driver.run(sql: "CREATE SEQUENCE IF NOT EXISTS \(DuckDBDialect.autoIncrementSequence)", binds: [])
        } catch {
            driver.close()
            throw error
        }
    }

    /// Release the database now, so a file database can be reopened straight away. Idempotent.
    func close() {
        closed = true
        driver.close()
    }

    /// Run one statement with bound parameters; return its rows (empty for DML without RETURNING).
    func run(sql: String, binds: [DuckDBValue]) throws -> [DuckDBSQLRow] {
        guard !closed else { throw DuckDBSQLError.shutDown }
        let rows = try driver.run(sql: sql, binds: binds)
        return Self.isCountOnlyDML(sql: sql, rows: rows) ? [] : rows
    }

    /// The version of the DuckDB library actually loaded, as DuckDB itself reports it.
    func libraryVersion() throws -> String {
        let rows = try run(sql: "SELECT version() AS version", binds: [])
        guard let first = rows.first, case .string(let version) = first.values.first else {
            throw DuckDBSQLError.typeMismatch("SELECT version() returned no text")
        }
        return version
    }

    /// INSERT/UPDATE/DELETE without RETURNING report a one-cell `Count` row; SQLKit expects no rows.
    private static func isCountOnlyDML(sql: String, rows: [DuckDBSQLRow]) -> Bool {
        guard rows.first?.columns == ["Count"] else { return false }
        let head = sql.drop(while: { $0.isWhitespace }).prefix(8).uppercased()
        let isDML = head.hasPrefix("INSERT") || head.hasPrefix("UPDATE") || head.hasPrefix("DELETE")
        return isDML && !sql.uppercased().contains("RETURNING")
    }
}
