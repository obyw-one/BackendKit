#if os(macOS) || os(iOS) || os(tvOS) || os(visionOS)
import DuckDB
import Foundation

// MARK: - DuckDBSwiftDriver (macOS, iOS, tvOS, visionOS: duckdb-swift)

//
// Apple platforms' side of the facade (`DuckDBDriverProtocol`). It owns a duckdb-swift `Database` and `Connection`;
// the engine actor is the only caller. Two things here exist for the 1:1 contract and are easy to lose:
//   - duckdb-swift reports a column whose Swift cast does not match as NIL, which is indistinguishable from NULL.
//     The column's DuckDB type is therefore read FIRST and matched to its one Swift type; a type this package does
//     not decode throws `unsupportedColumnType` instead of becoming NULL.
//   - duckdb-swift's own `DatabaseError` is translated to `DuckDBSQLError.engine(<DuckDB's text>)`, so a caller
//     sees the same error type whichever binding is compiled.

final class DuckDBSwiftDriver: DuckDBDriverProtocol {
    static var pinnedLibraryVersion: String { DuckDBVersionPins.appleLibraryVersion }

    private var database: Database?
    private var connection: Connection?

    init(storage: DuckDBSQLHost.Storage) throws {
        let store: Database.Store = switch storage {
        case .memory: .inMemory
        case .file(let path): .file(at: URL(fileURLWithPath: path))
        }
        do {
            let database = try Database(store: store)
            connection = try database.connect()
            self.database = database
        } catch {
            throw Self.translated(error)
        }
    }

    func close() {
        connection = nil
        database = nil
    }

    func run(sql: String, binds: [DuckDBValue]) throws -> [DuckDBSQLRow] {
        guard let connection else { throw DuckDBSQLError.shutDown }
        do {
            let statement = try PreparedStatement(connection: connection, query: sql)
            for (offset, value) in binds.enumerated() {
                try Self.bind(value, at: offset + 1, to: statement)
            }
            return try Self.rows(of: try statement.execute())
        } catch {
            throw Self.translated(error)
        }
    }

    // MARK: errors

    private static func translated(_ error: any Error) -> any Error {
        guard let failure = error as? DatabaseError else { return error }
        switch failure {
        case .connectionQueryError(let reason), .databaseFailedToInitialize(let reason),
             .preparedStatementFailedToInitialize(let reason), .preparedStatementFailedToBindParameter(let reason),
             .preparedStatementQueryError(let reason):
            return DuckDBSQLError.engine(reason ?? "\(failure)")
        case .decimalUnrepresentable:
            return DuckDBSQLError.unsupportedBind("a decimal DuckDB cannot represent")
        default:
            return DuckDBSQLError.engine("\(failure)")
        }
    }

    // MARK: bind

    private static func bind(_ value: DuckDBValue, at index: Int, to statement: PreparedStatement) throws {
        switch value {
        case .null: try statement.bind(nil as String?, at: index)
        case .bool(let v): try statement.bind(v, at: index)
        case .int(let v): try statement.bind(v, at: index)
        case .double(let v): try statement.bind(v, at: index)
        case .decimal(let v): try bindDecimal(v, at: index, to: statement)
        case .string(let v): try statement.bind(v, at: index)
        case .blob(let v): try statement.bind(v, at: index)
        case .date(let v): try statement.bind(try timestamp(v), at: index)
        }
    }

    /// duckdb-swift's own `bind(Decimal)` is not safe to call with an arbitrary `Decimal`: it multiplies the mantissa
    /// by the exponent (not by ten to the exponent) when `Decimal.exponent` is positive, so 100 binds as 2 and 1e30
    /// as 30, and a zero aborts the process. So the value is rebuilt, from the digits `DuckDBDecimalParts` accepted,
    /// as a `Decimal` with a zero-or-negative exponent and the whole unscaled integer as its mantissa, which that code
    /// binds exactly. Zero is bound as the integer 0 (see `DuckDBDecimalParts`).
    private static func bindDecimal(_ value: Decimal, at index: Int, to statement: PreparedStatement) throws {
        let parts = try DuckDBDecimalParts(value)
        if parts.isZero { return try statement.bind(Int64(0), at: index) }
        guard let magnitude = UIntHuge(parts.digits) else { throw DuckDBSQLError.unsupportedBind("decimal \(value)") }
        func word(_ shift: Int) -> UInt16 { UInt16(truncatingIfNeeded: magnitude >> shift) }
        let bits = magnitude.bitWidth - magnitude.leadingZeroBitCount
        let exact = Decimal(
            _exponent: Int32(-parts.scale),
            _length: UInt32((bits + 15) / 16),
            _isNegative: parts.isNegative ? 1 : 0,
            _isCompact: 0,
            _reserved: 0,
            _mantissa: (word(0), word(16), word(32), word(48), word(64), word(80), word(96), word(112))
        )
        try statement.bind(exact, at: index)
    }

    /// `Timestamp`'s memberwise init is internal to duckdb-swift (and its Foundation bridge scales by 1e3,
    /// not 1e6), so build it through its public `Codable` shape: microseconds since the Unix epoch.
    private static func timestamp(_ date: Foundation.Date) throws -> Timestamp {
        let micros = Int64((date.timeIntervalSince1970 * 1e6).rounded())
        return try JSONDecoder().decode(Timestamp.self, from: Data("{\"microseconds\":\(micros)}".utf8))
    }

    // MARK: rows

    private static func rows(of result: ResultSet) throws -> [DuckDBSQLRow] {
        let columnCount = Int(result.columnCount)
        let rowCount = Int(result.rowCount)
        guard columnCount > 0 else { return [] }
        // Every column is read even when there are no rows, so an undecoded column type is refused by the query's
        // shape, not by whether it happened to return data.
        let names = (0..<columnCount).map { result.columnName(at: DBInt($0)) }
        let cells = try (0..<columnCount).map { try values(of: result.column(at: DBInt($0)), named: names[$0], rows: rowCount) }
        return (0..<rowCount).map { row in
            DuckDBSQLRow(columns: names, values: cells.map { $0[row] })
        }
    }

    private static func map<T>(_ typed: Column<T>, rows: Int, _ convert: (T) -> DuckDBValue) -> [DuckDBValue] {
        (0..<rows).map { index in typed[DBInt(index)].map(convert) ?? .null }
    }

    private static func values(of column: Column<Void>, named name: String, rows: Int) throws -> [DuckDBValue] {
        // A column that is only NULL (DuckDB's NULL type: `SELECT NULL`, or a NULL parameter) has no data to read.
        if column.underlyingDatabaseType.rawValue == Self.nullTypeID { return [DuckDBValue](repeating: .null, count: rows) }
        if let values = integerValues(of: column, rows: rows) ?? temporalValues(of: column, rows: rows) ?? otherValues(of: column, rows: rows) {
            return values
        }
        throw DuckDBSQLError.unsupportedColumnType(column: name, type: typeName(column.underlyingDatabaseType))
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

    private static func otherValues(of column: Column<Void>, rows: Int) -> [DuckDBValue]? {
        switch column.underlyingDatabaseType {
        case .boolean: map(column.cast(to: Bool.self), rows: rows) { .bool($0) }
        case .float: map(column.cast(to: Float.self), rows: rows) { .double(Double($0)) }
        case .double: map(column.cast(to: Double.self), rows: rows) { .double($0) }
        case .decimal: map(column.cast(to: Decimal.self), rows: rows) { .decimal($0) }
        case .hugeint: map(column.cast(to: IntHuge.self), rows: rows) { .string("\($0)") }
        case .uhugeint: map(column.cast(to: UIntHuge.self), rows: rows) { .string("\($0)") }
        case .uuid: map(column.cast(to: UUID.self), rows: rows) { .string($0.uuidString) }
        case .blob: map(column.cast(to: Data.self), rows: rows) { .blob($0) }
        case .varchar: map(column.cast(to: String.self), rows: rows) { .string($0) }
        default: nil
        }
    }

    /// DuckDB's NULL type (`DUCKDB_TYPE_SQLNULL`), which duckdb-swift has no name for.
    private static let nullTypeID: UInt32 = 36
    private static let bitTypeID: UInt32 = 29
    private static let arrayTypeID: UInt32 = 33

    /// The DuckDB (SQL) names of the types this package does not decode, for the error message.
    private static let unsupportedNames: [UInt32: String] = [
        DatabaseType.time.rawValue: "TIME",
        DatabaseType.timeTz.rawValue: "TIME WITH TIME ZONE",
        DatabaseType.interval.rawValue: "INTERVAL",
        DatabaseType.enum.rawValue: "ENUM",
        DatabaseType.list.rawValue: "LIST",
        DatabaseType.struct.rawValue: "STRUCT",
        DatabaseType.map.rawValue: "MAP",
        DatabaseType.union.rawValue: "UNION",
        bitTypeID: "BIT",
        arrayTypeID: "ARRAY",
    ]

    private static func typeName(_ type: DatabaseType) -> String {
        unsupportedNames[type.rawValue] ?? "DuckDB type id \(type.rawValue)"
    }
}
#endif
