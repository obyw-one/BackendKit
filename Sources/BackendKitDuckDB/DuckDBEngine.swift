#if BACKENDKIT_DUCKDB
import DuckDB
import Foundation

// MARK: - DuckDBEngine

//
// The ONE actor that owns the DuckDB database + connection. DuckDB is in-process and
// single-writer, so every statement is serialised here; nothing else touches the C handle.
// Every value is BOUND through a prepared statement — SQL text never carries data.

actor DuckDBEngine {
    private let database: Database
    private let connection: Connection
    private var closed = false

    init(storage: DuckDBSQLHost.Storage) throws {
        let store: Database.Store = switch storage {
        case .memory: .inMemory
        case .file(let path): .file(at: URL(fileURLWithPath: path))
        }
        database = try Database(store: store)
        connection = try database.connect()
        try connection.execute("CREATE SEQUENCE IF NOT EXISTS \(DuckDBDialect.autoIncrementSequence)")
    }

    func close() { closed = true }

    /// Run one statement with bound parameters; return its rows (empty for DML without RETURNING).
    func run(sql: String, binds: [DuckDBValue]) throws -> [DuckDBSQLRow] {
        guard !closed else { throw DuckDBSQLError.typeMismatch("DuckDBSQLHost is shut down") }
        let statement = try PreparedStatement(connection: connection, query: sql)
        for (offset, value) in binds.enumerated() {
            try Self.bind(value, at: offset + 1, to: statement)
        }
        let result = try statement.execute()
        if Self.isCountOnlyDML(sql: sql, result: result) { return [] }
        return Self.rows(of: result)
    }

    // MARK: bind

    private static func bind(_ value: DuckDBValue, at index: Int, to statement: PreparedStatement) throws {
        switch value {
        case .null: try statement.bind(nil as String?, at: index)
        case .bool(let v): try statement.bind(v, at: index)
        case .int(let v): try statement.bind(v, at: index)
        case .double(let v): try statement.bind(v, at: index)
        case .decimal(let v): try statement.bind(v, at: index)
        case .string(let v): try statement.bind(v, at: index)
        case .blob(let v): try statement.bind(v, at: index)
        case .date(let v): try statement.bind(try timestamp(v), at: index)
        }
    }

    /// `Timestamp`'s memberwise init is internal to duckdb-swift (and its Foundation bridge scales by 1e3,
    /// not 1e6), so build it through its public `Codable` shape: microseconds since the Unix epoch.
    private static func timestamp(_ date: Foundation.Date) throws -> Timestamp {
        let micros = Int64((date.timeIntervalSince1970 * 1e6).rounded())
        return try JSONDecoder().decode(Timestamp.self, from: Data("{\"microseconds\":\(micros)}".utf8))
    }

    // MARK: rows

    /// INSERT/UPDATE/DELETE without RETURNING report a one-cell `Count` row; SQLKit expects no rows.
    private static func isCountOnlyDML(sql: String, result: ResultSet) -> Bool {
        guard result.columnCount == 1, result.columnName(at: 0) == "Count" else { return false }
        let head = sql.drop(while: { $0.isWhitespace }).prefix(8).uppercased()
        let isDML = head.hasPrefix("INSERT") || head.hasPrefix("UPDATE") || head.hasPrefix("DELETE")
        return isDML && !sql.uppercased().contains("RETURNING")
    }

    private static func rows(of result: ResultSet) -> [DuckDBSQLRow] {
        let columnCount = Int(result.columnCount)
        let rowCount = Int(result.rowCount)
        guard columnCount > 0, rowCount > 0 else { return [] }
        let names = (0..<columnCount).map { result.columnName(at: DBInt($0)) }
        let cells = (0..<columnCount).map { values(of: result.column(at: DBInt($0)), rows: rowCount) }
        return (0..<rowCount).map { row in
            DuckDBSQLRow(columns: names, values: cells.map { $0[row] })
        }
    }

    private static func map<T>(_ typed: Column<T>, rows: Int, _ convert: (T) -> DuckDBValue) -> [DuckDBValue] {
        (0..<rows).map { index in typed[DBInt(index)].map(convert) ?? .null }
    }

    private static func values(of column: Column<Void>, rows: Int) -> [DuckDBValue] {
        integerValues(of: column, rows: rows) ?? temporalValues(of: column, rows: rows) ?? otherValues(of: column, rows: rows)
    }

    private static func integerValues(of column: Column<Void>, rows: Int) -> [DuckDBValue]? {
        switch column.underlyingDatabaseType {
        case .tinyint: map(column.cast(to: Int8.self), rows: rows) { .int(Int64($0)) }
        case .smallint: map(column.cast(to: Int16.self), rows: rows) { .int(Int64($0)) }
        case .integer: map(column.cast(to: Int32.self), rows: rows) { .int(Int64($0)) }
        case .bigint: map(column.cast(to: Int64.self), rows: rows) { .int($0) }
        case .utinyint: map(column.cast(to: UInt8.self), rows: rows) { .int(Int64($0)) }
        case .usmallint: map(column.cast(to: UInt16.self), rows: rows) { .int(Int64($0)) }
        case .uinteger: map(column.cast(to: UInt32.self), rows: rows) { .int(Int64($0)) }
        case .ubigint:
            map(column.cast(to: UInt64.self), rows: rows) { $0 <= UInt64(Int64.max) ? .int(Int64($0)) : .string(String($0)) }
        default: nil
        }
    }

    private static func temporalValues(of column: Column<Void>, rows: Int) -> [DuckDBValue]? {
        switch column.underlyingDatabaseType {
        case .date:
            map(column.cast(to: DuckDB.Date.self), rows: rows) { .date(Foundation.Date(timeIntervalSince1970: Double($0.days) * 86400)) }
        case .timestamp, .timestampTz, .timestampS, .timestampMS, .timestampNS:
            map(column.cast(to: Timestamp.self), rows: rows) { .date(Foundation.Date(timeIntervalSince1970: Double($0.microseconds) / 1e6)) }
        default: nil
        }
    }

    private static func otherValues(of column: Column<Void>, rows: Int) -> [DuckDBValue] {
        switch column.underlyingDatabaseType {
        case .boolean: map(column.cast(to: Bool.self), rows: rows) { .bool($0) }
        case .float: map(column.cast(to: Float.self), rows: rows) { .double(Double($0)) }
        case .double: map(column.cast(to: Double.self), rows: rows) { .double($0) }
        case .decimal: map(column.cast(to: Decimal.self), rows: rows) { .decimal($0) }
        case .hugeint: map(column.cast(to: IntHuge.self), rows: rows) { .string("\($0)") }
        case .uhugeint: map(column.cast(to: UIntHuge.self), rows: rows) { .string("\($0)") }
        case .uuid: map(column.cast(to: UUID.self), rows: rows) { .string($0.uuidString) }
        case .blob: map(column.cast(to: Data.self), rows: rows) { .blob($0) }
        // varchar, enum and anything else DuckDB can render as text.
        default: map(column.cast(to: String.self), rows: rows) { .string($0) }
        }
    }
}
#endif
