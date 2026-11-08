#if os(Linux)
import CDuckDB
import Foundation

// MARK: - DuckDBCAPIDriver (Linux: the official libduckdb through its C API)

//
// Linux's side of the facade (`DuckDBDriverProtocol`). It owns one `duckdb_database` and one `duckdb_connection`;
// the engine actor is the only caller, so the handles are never touched from two threads at once and the class is
// (honestly) not `Sendable`. Results are read through `duckdb_fetch_chunk` and the chunks' vectors — the supported
// path — never through the deprecated `duckdb_value_*` accessors.
//
// Rules this file keeps, each one a place the C API makes a mistake easy:
//   - every call that can fail is checked, and the failure is thrown with DuckDB's OWN text
//     (`duckdb_open_ext`'s error, `duckdb_prepare_error`, `duckdb_result_error`) as `DuckDBSQLError.engine`;
//   - every handle (statement, result, logical type, chunk, error string, enum string) is released by a `defer` or by
//     `deinit`, so a throw at any line frees what was allocated before it;
//   - a column type this package does not decode is refused (`unsupportedColumnType`), never read as NULL;
//   - a value that cannot be represented (a timestamp scaled past Int64) throws instead of wrapping.

final class DuckDBCAPIDriver: DuckDBDriverProtocol {
    static var pinnedLibraryVersion: String { DuckDBVersionPins.linuxLibraryVersion }

    private var database: duckdb_database?
    private var connection: duckdb_connection?

    init(storage: DuckDBSQLHost.Storage) throws {
        let path: String? = switch storage {
        case .memory: nil
        case .file(let path): path
        }
        var openedDatabase: duckdb_database?
        var errorText: UnsafeMutablePointer<CChar>?
        guard duckdb_open_ext(path, &openedDatabase, nil, &errorText) == DuckDBSuccess else {
            let message = Self.takeString(errorText) ?? "DuckDB could not open the database"
            duckdb_close(&openedDatabase)
            throw DuckDBSQLError.engine(message)
        }
        var openedConnection: duckdb_connection?
        guard duckdb_connect(openedDatabase, &openedConnection) == DuckDBSuccess else {
            duckdb_close(&openedDatabase)
            throw DuckDBSQLError.engine("DuckDB could not open a connection to the database")
        }
        database = openedDatabase
        connection = openedConnection
    }

    deinit { close() }

    func close() {
        duckdb_disconnect(&connection)
        duckdb_close(&database)
    }

    func run(sql: String, binds: [DuckDBValue]) throws -> [DuckDBSQLRow] {
        guard let connection else { throw DuckDBSQLError.shutDown }
        var statement: duckdb_prepared_statement?
        defer { duckdb_destroy_prepare(&statement) }
        guard duckdb_prepare(connection, sql, &statement) == DuckDBSuccess else {
            throw DuckDBSQLError.engine(Self.string(duckdb_prepare_error(statement)) ?? "DuckDB could not prepare the statement")
        }
        for (offset, value) in binds.enumerated() {
            try Self.bind(value, at: idx_t(offset + 1), to: statement)
        }
        var result = duckdb_result()
        defer { duckdb_destroy_result(&result) }
        guard duckdb_execute_prepared(statement, &result) == DuckDBSuccess else {
            throw DuckDBSQLError.engine(Self.string(duckdb_result_error(&result)) ?? "DuckDB could not execute the statement")
        }
        return try Self.rows(of: &result)
    }

    // MARK: C strings

    /// A C string DuckDB owns (an error, a column name): copied, not freed.
    private static func string(_ pointer: UnsafePointer<CChar>?) -> String? {
        pointer.map { String(cString: $0) }
    }

    /// A C string the caller must free with `duckdb_free`: copied, then freed.
    private static func takeString(_ pointer: UnsafeMutablePointer<CChar>?) -> String? {
        guard let pointer else { return nil }
        defer { duckdb_free(pointer) }
        return String(cString: pointer)
    }

    // MARK: bind

    private static func bind(_ value: DuckDBValue, at index: idx_t, to statement: duckdb_prepared_statement?) throws {
        let state: duckdb_state
        switch value {
        case .null: state = duckdb_bind_null(statement, index)
        case .bool(let v): state = duckdb_bind_boolean(statement, index, v)
        case .int(let v): state = duckdb_bind_int64(statement, index, v)
        case .double(let v): state = duckdb_bind_double(statement, index, v)
        case .decimal(let v): state = try bindDecimal(v, at: index, to: statement)
        case .string(let v):
            // By length, so a NUL inside the string is data and not the end of it. The terminator makes the buffer
            // non-empty, because an empty array's base address may be nil and DuckDB rejects a nil pointer.
            let bytes = Array(v.utf8) + [0]
            state = bytes.withUnsafeBufferPointer {
                $0.baseAddress!.withMemoryRebound(to: CChar.self, capacity: bytes.count) {
                    duckdb_bind_varchar_length(statement, index, $0, idx_t(bytes.count - 1))
                }
            }
        case .blob(let v):
            let bytes = [UInt8](v) + [0]
            state = bytes.withUnsafeBufferPointer { duckdb_bind_blob(statement, index, $0.baseAddress!, idx_t(bytes.count - 1)) }
        case .date(let v):
            state = duckdb_bind_timestamp(statement, index, duckdb_timestamp(micros: Int64((v.timeIntervalSince1970 * 1e6).rounded())))
        }
        guard state == DuckDBSuccess else {
            throw DuckDBSQLError.engine(string(duckdb_prepare_error(statement)) ?? "DuckDB could not bind parameter \(index) (\(value))")
        }
    }

    private static func bindDecimal(_ value: Decimal, at index: idx_t, to statement: duckdb_prepared_statement?) throws -> duckdb_state {
        let parts = try DuckDBDecimalParts(value)
        if parts.isZero { return duckdb_bind_int64(statement, index, 0) }
        guard let magnitude = Int128(parts.digits) else { throw DuckDBSQLError.unsupportedBind("decimal \(value)") }
        let unscaled = parts.isNegative ? -magnitude : magnitude
        return duckdb_bind_decimal(
            statement,
            index,
            duckdb_decimal(width: UInt8(DuckDBDecimalParts.maxDigits), scale: UInt8(parts.scale), value: duckdb_hugeint(unscaled))
        )
    }

    // MARK: rows

    private static func rows(of result: inout duckdb_result) throws -> [DuckDBSQLRow] {
        let columnCount = Int(duckdb_column_count(&result))
        guard columnCount > 0 else { return [] }
        let names = (0..<columnCount).map { string(duckdb_column_name(&result, idx_t($0))) ?? "" }
        let kinds = try (0..<columnCount).map { try ColumnKind(of: &result, column: $0, named: names[$0]) }
        var cells = [[DuckDBValue]](repeating: [], count: columnCount)
        while true {
            // fetch_chunk takes the result by value; a nil chunk is the end of the result (or an error, checked below).
            var chunk = duckdb_fetch_chunk(result)
            guard chunk != nil else { break }
            defer { duckdb_destroy_data_chunk(&chunk) }
            let count = Int(duckdb_data_chunk_get_size(chunk))
            for (index, kind) in kinds.enumerated() {
                let vector = duckdb_data_chunk_get_vector(chunk, idx_t(index))
                cells[index].append(contentsOf: try kind.values(
                    data: duckdb_vector_get_data(vector), validity: duckdb_vector_get_validity(vector), count: count, column: names[index]
                ))
            }
        }
        if let failure = string(duckdb_result_error(&result)) { throw DuckDBSQLError.engine(failure) }
        return (0..<(cells.first?.count ?? 0)).map { row in DuckDBSQLRow(columns: names, values: cells.map { $0[row] }) }
    }
}

// MARK: - Column kinds

/// How one result column is read out of its vector. Built once per result from the column's logical type, which is
/// destroyed again before the kind is returned: a kind holds plain values only.
private enum ColumnKind {
    case boolean
    case int8, int16, int32, int64
    case uint8, uint16, uint32, uint64
    case float, double
    case date
    case timestamp(TimestampUnit)
    case decimal(scale: Int, storage: DecimalStorage)
    case hugeint, uhugeint, uuid, blob, varchar
    /// A column that is only NULL (DuckDB's NULL type): there is no data to read.
    case null

    enum DecimalStorage { case int16, int32, int64, int128 }

    /// The unit a TIMESTAMP column stores. Every one is normalised to microseconds before it becomes a `Date`, with the
    /// same integer arithmetic duckdb-swift applies (seconds and milliseconds scale up, nanoseconds divide down).
    enum TimestampUnit {
        case seconds, milliseconds, microseconds, nanoseconds

        func microseconds(_ stored: Int64, column: String) throws -> Int64 {
            let factor: Int64
            switch self {
            case .microseconds: return stored
            case .nanoseconds: return stored / 1_000
            case .seconds: factor = 1_000_000
            case .milliseconds: factor = 1_000
            }
            let (scaled, overflow) = stored.multipliedReportingOverflow(by: factor)
            if overflow { throw DuckDBSQLError.typeMismatch("column \"\(column)\": timestamp \(stored) overflows microseconds") }
            return scaled
        }
    }

    init(of result: inout duckdb_result, column: Int, named name: String) throws {
        var logical = duckdb_column_logical_type(&result, idx_t(column))
        defer { duckdb_destroy_logical_type(&logical) }
        let id = duckdb_get_type_id(logical)
        if let kind = Self.integerKind(id) ?? Self.temporalKind(id) ?? Self.otherKind(id) {
            self = kind
        } else if id == DUCKDB_TYPE_DECIMAL {
            self = try Self.decimalKind(logical, named: name)
        } else {
            throw DuckDBSQLError.unsupportedColumnType(column: name, type: Self.unsupportedTypeName(id))
        }
    }

    private static func integerKind(_ id: duckdb_type) -> ColumnKind? {
        switch id {
        case DUCKDB_TYPE_TINYINT: .int8
        case DUCKDB_TYPE_SMALLINT: .int16
        case DUCKDB_TYPE_INTEGER: .int32
        case DUCKDB_TYPE_BIGINT: .int64
        case DUCKDB_TYPE_UTINYINT: .uint8
        case DUCKDB_TYPE_USMALLINT: .uint16
        case DUCKDB_TYPE_UINTEGER: .uint32
        case DUCKDB_TYPE_UBIGINT: .uint64
        default: nil
        }
    }

    private static func temporalKind(_ id: duckdb_type) -> ColumnKind? {
        switch id {
        case DUCKDB_TYPE_DATE: .date
        case DUCKDB_TYPE_TIMESTAMP, DUCKDB_TYPE_TIMESTAMP_TZ: .timestamp(.microseconds)
        case DUCKDB_TYPE_TIMESTAMP_S: .timestamp(.seconds)
        case DUCKDB_TYPE_TIMESTAMP_MS: .timestamp(.milliseconds)
        case DUCKDB_TYPE_TIMESTAMP_NS: .timestamp(.nanoseconds)
        default: nil
        }
    }

    private static func otherKind(_ id: duckdb_type) -> ColumnKind? {
        switch id {
        case DUCKDB_TYPE_BOOLEAN: .boolean
        case DUCKDB_TYPE_FLOAT: .float
        case DUCKDB_TYPE_DOUBLE: .double
        case DUCKDB_TYPE_HUGEINT: .hugeint
        case DUCKDB_TYPE_UHUGEINT: .uhugeint
        case DUCKDB_TYPE_UUID: .uuid
        case DUCKDB_TYPE_BLOB: .blob
        case DUCKDB_TYPE_VARCHAR: .varchar
        case DUCKDB_TYPE_SQLNULL: .null
        default: nil
        }
    }

    private static func decimalKind(_ logical: duckdb_logical_type?, named name: String) throws -> ColumnKind {
        let storage: DecimalStorage
        switch duckdb_decimal_internal_type(logical) {
        case DUCKDB_TYPE_SMALLINT: storage = .int16
        case DUCKDB_TYPE_INTEGER: storage = .int32
        case DUCKDB_TYPE_BIGINT: storage = .int64
        case DUCKDB_TYPE_HUGEINT: storage = .int128
        default: throw DuckDBSQLError.unsupportedColumnType(column: name, type: "DECIMAL")
        }
        return .decimal(scale: Int(duckdb_decimal_scale(logical)), storage: storage)
    }

    /// The DuckDB (SQL) name of a type this package does not decode, for the error message.
    private static let unsupportedNames: [UInt32: String] = [
        DUCKDB_TYPE_TIME.rawValue: "TIME",
        DUCKDB_TYPE_TIME_TZ.rawValue: "TIME WITH TIME ZONE",
        DUCKDB_TYPE_INTERVAL.rawValue: "INTERVAL",
        DUCKDB_TYPE_ENUM.rawValue: "ENUM",
        DUCKDB_TYPE_LIST.rawValue: "LIST",
        DUCKDB_TYPE_STRUCT.rawValue: "STRUCT",
        DUCKDB_TYPE_MAP.rawValue: "MAP",
        DUCKDB_TYPE_UNION.rawValue: "UNION",
        DUCKDB_TYPE_ARRAY.rawValue: "ARRAY",
        DUCKDB_TYPE_BIT.rawValue: "BIT",
    ]

    private static func unsupportedTypeName(_ id: duckdb_type) -> String {
        unsupportedNames[id.rawValue] ?? "DuckDB type id \(id.rawValue)"
    }

    // MARK: reading a vector

    /// The cells of one vector: `count` rows of this column, NULLs from the validity mask.
    func values(data: UnsafeMutableRawPointer?, validity: UnsafeMutablePointer<UInt64>?, count: Int, column: String) throws -> [DuckDBValue] {
        guard count > 0 else { return [] }
        if case .null = self { return [DuckDBValue](repeating: .null, count: count) }
        guard let data else { throw DuckDBSQLError.engine("DuckDB returned no data for column \"\(column)\"") }
        let vector = VectorReader(data: data, validity: validity, count: count)
        if let cells = try integerCells(vector) ?? scalarCells(vector) ?? temporalCells(vector, column: column)
            ?? decimalCells(vector) ?? textCells(vector) {
            return cells
        }
        throw DuckDBSQLError.engine("column \"\(column)\" has a kind with no reader")
    }

    private func integerCells(_ vector: VectorReader) throws -> [DuckDBValue]? {
        switch self {
        case .int8: try vector.read(Int8.self) { .int(Int64($0)) }
        case .int16: try vector.read(Int16.self) { .int(Int64($0)) }
        case .int32: try vector.read(Int32.self) { .int(Int64($0)) }
        case .int64: try vector.read(Int64.self) { .int($0) }
        case .uint8: try vector.read(UInt8.self) { .int(Int64($0)) }
        case .uint16: try vector.read(UInt16.self) { .int(Int64($0)) }
        case .uint32: try vector.read(UInt32.self) { .int(Int64($0)) }
        case .uint64: try vector.read(UInt64.self) { $0 <= UInt64(Int64.max) ? .int(Int64($0)) : .string(String($0)) }
        default: nil
        }
    }

    private func scalarCells(_ vector: VectorReader) throws -> [DuckDBValue]? {
        switch self {
        case .boolean: try vector.read(UInt8.self) { .bool($0 != 0) }
        case .float: try vector.read(Float.self) { .double(Double($0)) }
        case .double: try vector.read(Double.self) { .double($0) }
        case .hugeint: try vector.read(duckdb_hugeint.self) { .string(String(Int128($0))) }
        case .uhugeint: try vector.read(duckdb_uhugeint.self) { .string(String(UInt128($0))) }
        default: nil
        }
    }

    private func temporalCells(_ vector: VectorReader, column: String) throws -> [DuckDBValue]? {
        switch self {
        case .date:
            return try vector.read(duckdb_date.self) { .date(Date(timeIntervalSince1970: Double($0.days) * 86400)) }
        case .timestamp(let unit):
            return try vector.read(duckdb_timestamp.self) {
                .date(Date(timeIntervalSince1970: Double(try unit.microseconds($0.micros, column: column)) / 1e6))
            }
        default:
            return nil
        }
    }

    private func decimalCells(_ vector: VectorReader) throws -> [DuckDBValue]? {
        guard case .decimal(let scale, let storage) = self else { return nil }
        switch storage {
        case .int16: return try vector.read(Int16.self) { .decimal(try Self.decimal(unscaled: Int128($0), scale: scale)) }
        case .int32: return try vector.read(Int32.self) { .decimal(try Self.decimal(unscaled: Int128($0), scale: scale)) }
        case .int64: return try vector.read(Int64.self) { .decimal(try Self.decimal(unscaled: Int128($0), scale: scale)) }
        case .int128: return try vector.read(duckdb_hugeint.self) { .decimal(try Self.decimal(unscaled: Int128($0), scale: scale)) }
        }
    }

    private func textCells(_ vector: VectorReader) throws -> [DuckDBValue]? {
        switch self {
        case .uuid: try vector.read(duckdb_hugeint.self) { .string(Self.uuid($0).uuidString) }
        case .blob: try vector.read(duckdb_string_t.self) { .blob(Data(Self.bytes(of: $0))) }
        case .varchar:
            try vector.read(duckdb_string_t.self) {
                guard let text = String(bytes: Self.bytes(of: $0), encoding: .utf8) else {
                    throw DuckDBSQLError.typeMismatch("DuckDB returned a VARCHAR that is not valid UTF-8")
                }
                return .string(text)
            }
        default: nil
        }
    }

    // MARK: cell conversions

    /// The bytes of a `duckdb_string_t` (a VARCHAR or BLOB cell: inlined when short, else behind a pointer), copied
    /// out. The copy is made here because an inlined cell's bytes live inside the struct itself, which is a local copy.
    private static func bytes(of cell: duckdb_string_t) -> [UInt8] {
        var cell = cell
        let length = Int(duckdb_string_t_length(cell))
        guard length > 0, let pointer = duckdb_string_t_data(&cell) else { return [] }
        return Array(UnsafeBufferPointer(start: UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self), count: length))
    }

    /// An unscaled DECIMAL integer and its scale as a Foundation `Decimal`, exactly (38 digits fit its 128-bit mantissa).
    private static func decimal(unscaled: Int128, scale: Int) throws -> Decimal {
        let sign: FloatingPointSign = unscaled < 0 ? .minus : .plus
        let magnitude = unscaled.magnitude
        if let small = UInt64(exactly: magnitude) {
            return Decimal(sign: sign, exponent: -scale, significand: Decimal(small))
        }
        // Beyond 64 bits the exact value is built from its digits: `Decimal(string:)` keeps all 38.
        var digits = String(magnitude)
        if digits.count <= scale { digits = String(repeating: "0", count: scale - digits.count + 1) + digits }
        let point = digits.index(digits.endIndex, offsetBy: -scale)
        let text = (sign == .minus ? "-" : "") + digits[..<point] + (scale > 0 ? "." + digits[point...] : "")
        guard let value = Decimal(string: text) else { throw DuckDBSQLError.typeMismatch("DuckDB decimal \(text) is not representable") }
        return value
    }

    /// DuckDB stores a UUID as a HUGEINT with the sign bit of the upper half flipped (so UUIDs sort as unsigned).
    private static func uuid(_ stored: duckdb_hugeint) -> UUID {
        let upper = UInt64(bitPattern: stored.upper) ^ 0x8000_0000_0000_0000
        var raw = [UInt8](repeating: 0, count: 16)
        for offset in 0..<8 {
            raw[offset] = UInt8(truncatingIfNeeded: upper >> UInt64(56 - 8 * offset))
            raw[8 + offset] = UInt8(truncatingIfNeeded: stored.lower >> UInt64(56 - 8 * offset))
        }
        return UUID(uuid: (raw[0], raw[1], raw[2], raw[3], raw[4], raw[5], raw[6], raw[7],
                           raw[8], raw[9], raw[10], raw[11], raw[12], raw[13], raw[14], raw[15]))
    }
}

// MARK: - VectorReader

/// One column's data pointer and validity mask for the rows of one chunk.
private struct VectorReader {
    let data: UnsafeMutableRawPointer
    let validity: UnsafeMutablePointer<UInt64>?
    let count: Int

    /// Each row as `T` (the vector's native layout for the column's type), NULL where the validity mask says so.
    func read<T>(_ type: T.Type, _ convert: (T) throws -> DuckDBValue) throws -> [DuckDBValue] {
        let base = data.assumingMemoryBound(to: T.self)
        return try (0..<count).map { row in
            guard validity == nil || duckdb_validity_row_is_valid(validity, idx_t(row)) else { return DuckDBValue.null }
            return try convert(base[row])
        }
    }
}

// MARK: - 128-bit conversions

private extension Int128 {
    init(_ value: duckdb_hugeint) { self = (Int128(value.upper) << 64) | Int128(value.lower) }
}

private extension UInt128 {
    init(_ value: duckdb_uhugeint) { self = (UInt128(value.upper) << 64) | UInt128(value.lower) }
}

private extension duckdb_hugeint {
    init(_ value: Int128) {
        self.init(lower: UInt64(truncatingIfNeeded: value), upper: Int64(truncatingIfNeeded: value >> 64))
    }
}
#endif
