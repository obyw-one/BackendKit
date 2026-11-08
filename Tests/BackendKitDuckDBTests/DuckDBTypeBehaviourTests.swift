import Foundation
import Testing

@testable import BackendKitDuckDB

// MARK: - DuckDBTypeBehaviourTests

//
// ONE behaviour suite for BOTH drivers. These tests are compiled unchanged on every platform: on macOS, iOS, tvOS and visionOS
// they run against duckdb-swift (`DuckDBSwiftDriver`), on Linux against the official libduckdb through its C API
// (`DuckDBCAPIDriver`). They talk to `DuckDBEngine`, the facade's one consumer, and read the cells it hands back, so
// "the same behaviour" means "the same `DuckDBValue` for the same SQL". A test must never be weakened or branched
// by platform to make the two agree; if the two DuckDB versions disagree, that test is the evidence and the
// difference is recorded in the comment above it ("Known difference").

/// A scratch engine: opened, handed to the body, closed again on every path.
@discardableResult
func withDuckDBEngine<T>(_ storage: DuckDBSQLHost.Storage = .memory, _ body: (DuckDBEngine) async throws -> T) async throws -> T {
    let engine = try DuckDBEngine(storage: storage)
    do {
        let result = try await body(engine)
        await engine.close()
        return result
    } catch {
        await engine.close()
        throw error
    }
}

/// The rows of one statement on a scratch in-memory database.
func duckDBRows(_ sql: String, binds: [DuckDBValue] = []) async throws -> [DuckDBSQLRow] {
    try await withDuckDBEngine { try await $0.run(sql: sql, binds: binds) }
}

/// The first cell of the first row.
func duckDBCell(_ sql: String, binds: [DuckDBValue] = []) async throws -> DuckDBValue {
    let rows = try await duckDBRows(sql, binds: binds)
    return try #require(rows.first?.values.first, "no row for \(sql)")
}

struct CellCase: Sendable, CustomTestStringConvertible {
    let sql: String
    let expected: DuckDBValue
    var testDescription: String { sql }
    init(_ sql: String, _ expected: DuckDBValue) {
        self.sql = sql
        self.expected = expected
    }
}

private func decimal(_ text: String) -> DuckDBValue { .decimal(Decimal(string: text)!) }
private func seconds(_ value: Double) -> DuckDBValue { .date(Date(timeIntervalSince1970: value)) }

// MARK: - Integers, floats, booleans

@Suite("Driver behaviour — numeric and boolean cells")
struct DuckDBNumericBehaviourTests {
    static let integers: [CellCase] = [
        CellCase("SELECT '-128'::TINYINT", .int(-128)),
        CellCase("SELECT '127'::TINYINT", .int(127)),
        CellCase("SELECT '-32768'::SMALLINT", .int(-32768)),
        CellCase("SELECT '32767'::SMALLINT", .int(32767)),
        CellCase("SELECT '-2147483648'::INTEGER", .int(-2_147_483_648)),
        CellCase("SELECT '2147483647'::INTEGER", .int(2_147_483_647)),
        CellCase("SELECT '-9223372036854775808'::BIGINT", .int(Int64.min)),
        CellCase("SELECT '9223372036854775807'::BIGINT", .int(Int64.max)),
        CellCase("SELECT '255'::UTINYINT", .int(255)),
        CellCase("SELECT '65535'::USMALLINT", .int(65535)),
        CellCase("SELECT '4294967295'::UINTEGER", .int(4_294_967_295)),
        CellCase("SELECT '0'::UBIGINT", .int(0)),
        CellCase("SELECT '9223372036854775807'::UBIGINT", .int(Int64.max)),
        // A UBIGINT above Int64.max cannot be an `.int`: it is carried as its decimal text, not wrapped or clamped.
        CellCase("SELECT '9223372036854775808'::UBIGINT", .string("9223372036854775808")),
        CellCase("SELECT '18446744073709551615'::UBIGINT", .string("18446744073709551615")),
    ]

    @Test("every integer width, at its extremes", arguments: integers)
    func integerCells(_ test: CellCase) async throws {
        #expect(try await duckDBCell(test.sql) == test.expected)
    }

    static let hugeIntegers: [CellCase] = [
        CellCase("SELECT '-170141183460469231731687303715884105728'::HUGEINT", .string("-170141183460469231731687303715884105728")),
        CellCase("SELECT '170141183460469231731687303715884105727'::HUGEINT", .string("170141183460469231731687303715884105727")),
        CellCase("SELECT '0'::HUGEINT", .string("0")),
        CellCase("SELECT '-1'::HUGEINT", .string("-1")),
        CellCase("SELECT '18446744073709551616'::HUGEINT", .string("18446744073709551616")),
        CellCase("SELECT '-18446744073709551617'::HUGEINT", .string("-18446744073709551617")),
        CellCase("SELECT '0'::UHUGEINT", .string("0")),
        CellCase("SELECT '340282366920938463463374607431768211455'::UHUGEINT", .string("340282366920938463463374607431768211455")),
        CellCase("SELECT '18446744073709551616'::UHUGEINT", .string("18446744073709551616")),
    ]

    @Test("HUGEINT and UHUGEINT keep all 128 bits, as decimal text", arguments: hugeIntegers)
    func hugeIntegerCells(_ test: CellCase) async throws {
        #expect(try await duckDBCell(test.sql) == test.expected)
    }

    static let floats: [CellCase] = [
        CellCase("SELECT '1.5'::FLOAT", .double(1.5)),
        CellCase("SELECT '0.1'::FLOAT", .double(Double(Float(0.1)))),
        CellCase("SELECT '-0.25'::DOUBLE", .double(-0.25)),
        CellCase("SELECT '0.1'::DOUBLE", .double(0.1)),
        CellCase("SELECT '1e308'::DOUBLE", .double(1e308)),
        CellCase("SELECT 'Infinity'::DOUBLE", .double(.infinity)),
        CellCase("SELECT '-Infinity'::DOUBLE", .double(-.infinity)),
        CellCase("SELECT 'Infinity'::FLOAT", .double(.infinity)),
    ]

    @Test("FLOAT and DOUBLE", arguments: floats)
    func floatCells(_ test: CellCase) async throws {
        #expect(try await duckDBCell(test.sql) == test.expected)
    }

    @Test("NaN stays NaN (it is not equal to itself, so it is checked by value)")
    func nanCells() async throws {
        for sql in ["SELECT 'NaN'::DOUBLE", "SELECT 'NaN'::FLOAT"] {
            guard case .double(let value) = try await duckDBCell(sql) else {
                Issue.record("\(sql) did not give a double")
                continue
            }
            #expect(value.isNaN)
        }
    }

    @Test("booleans")
    func booleanCells() async throws {
        #expect(try await duckDBCell("SELECT true") == .bool(true))
        #expect(try await duckDBCell("SELECT false") == .bool(false))
    }
}

// MARK: - Text and bytes

@Suite("Driver behaviour — text and blob cells")
struct DuckDBTextBehaviourTests {
    // DuckDB stores strings of up to 12 bytes inline and longer ones behind a pointer; both sides of that edge are read.
    static let strings: [CellCase] = [
        CellCase("SELECT ''", .string("")),
        CellCase("SELECT 'x'", .string("x")),
        CellCase("SELECT 'twelve bytes'", .string("twelve bytes")),
        CellCase("SELECT 'thirteen byte'", .string("thirteen byte")),
        CellCase("SELECT 'héllo 🦆 wörld'", .string("héllo 🦆 wörld")),
        CellCase("SELECT repeat('ab', 5000)", .string(String(repeating: "ab", count: 5000))),
        CellCase("SELECT 'it''s \"quoted\" \\ back'", .string("it's \"quoted\" \\ back")),
    ]

    @Test("VARCHAR: empty, inline, pointer, non-ASCII, long", arguments: strings)
    func stringCells(_ test: CellCase) async throws {
        #expect(try await duckDBCell(test.sql) == test.expected)
    }

    static let blobs: [CellCase] = [
        CellCase("SELECT ''::BLOB", .blob(Data())),
        CellCase("SELECT from_hex('aa00bb')", .blob(Data([0xAA, 0x00, 0xBB]))),
        CellCase("SELECT from_hex('000102030405060708090a0b')", .blob(Data(0..<12))),
        CellCase("SELECT from_hex('000102030405060708090a0b0c')", .blob(Data(0..<13))),
        CellCase("SELECT from_hex(repeat('ab', 1000))", .blob(Data(repeating: 0xAB, count: 1000))),
    ]

    @Test("BLOB: empty, with a NUL byte, inline, pointer, long", arguments: blobs)
    func blobCells(_ test: CellCase) async throws {
        #expect(try await duckDBCell(test.sql) == test.expected)
    }

    @Test("a UUID comes back as its uppercase text, including the all-zero and all-one edges")
    func uuidCells() async throws {
        let cases: [(String, String)] = [
            ("a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11", "A0EEBC99-9C0B-4EF8-BB6D-6BB9BD380A11"),
            ("00000000-0000-0000-0000-000000000000", "00000000-0000-0000-0000-000000000000"),
            ("ffffffff-ffff-ffff-ffff-ffffffffffff", "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF"),
            ("80000000-0000-0000-0000-000000000000", "80000000-0000-0000-0000-000000000000"),
            ("7fffffff-ffff-ffff-ffff-ffffffffffff", "7FFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF"),
            ("12345678-9abc-def0-1234-56789abcdef0", "12345678-9ABC-DEF0-1234-56789ABCDEF0"),
        ]
        for (literal, expected) in cases {
            #expect(try await duckDBCell("SELECT '\(literal)'::UUID") == .string(expected), "\(literal)")
        }
    }

    @Test("a string bound with a NUL inside is data, not a terminator, and an empty string and empty blob can be bound")
    func bindsKeepEveryByte() async throws {
        let withNUL = "before\u{0}after"
        #expect(try await duckDBCell("SELECT $1", binds: [.string(withNUL)]) == .string(withNUL))
        #expect(try await duckDBCell("SELECT $1", binds: [.string("")]) == .string(""))
        #expect(try await duckDBCell("SELECT $1", binds: [.blob(Data())]) == .blob(Data()))
        let bytes = Data([0x00, 0xFF, 0x00, 0x7F])
        #expect(try await duckDBCell("SELECT $1", binds: [.blob(bytes)]) == .blob(bytes))
        let long = String(repeating: "é", count: 4000)
        #expect(try await duckDBCell("SELECT $1", binds: [.string(long)]) == .string(long))
    }
}

// MARK: - Dates and times

@Suite("Driver behaviour — date and timestamp cells")
struct DuckDBTemporalBehaviourTests {
    // 2026-11-07 12:34:56 UTC is 1_794_054_896 s after the Unix epoch; its day number is 20_764.
    static let instant = 1_794_054_896.0

    static let dates: [CellCase] = [
        CellCase("SELECT DATE '1970-01-01'", seconds(0)),
        CellCase("SELECT DATE '1969-12-31'", seconds(-86400)),
        CellCase("SELECT DATE '2026-11-07'", seconds(20764 * 86400)),
        CellCase("SELECT DATE '1900-01-01'", seconds(-25567 * 86400)),
        CellCase("SELECT DATE '9999-12-31'", seconds(2_932_896 * 86400)),
    ]

    @Test("DATE: epoch, before the epoch, today, far past and future", arguments: dates)
    func dateCells(_ test: CellCase) async throws {
        #expect(try await duckDBCell(test.sql) == test.expected)
    }

    // Every timestamp flavour becomes microseconds since the epoch before it becomes a `Date`: seconds and
    // milliseconds scale up, nanoseconds divide down (truncating toward zero).
    static let timestamps: [CellCase] = [
        CellCase("SELECT TIMESTAMP '1970-01-01 00:00:00'", seconds(0)),
        CellCase("SELECT TIMESTAMP '2026-11-07 12:34:56'", seconds(instant)),
        CellCase("SELECT TIMESTAMP '2026-11-07 12:34:56.789012'", seconds(Double(1_794_054_896_789_012) / 1e6)),
        CellCase("SELECT TIMESTAMP '1969-12-31 23:59:59.999999'", seconds(-1.0 / 1e6)),
        CellCase("SELECT TIMESTAMP '1900-01-01 00:00:00'", seconds(-2_208_988_800)),
        CellCase("SELECT TIMESTAMPTZ '2026-11-07 12:34:56.5+00'", seconds(Double(1_794_054_896_500_000) / 1e6)),
        CellCase("SELECT TIMESTAMPTZ '2026-11-07 14:34:56+02'", seconds(instant)),
        CellCase("SELECT TIMESTAMP_S '2026-11-07 12:34:56'", seconds(instant)),
        CellCase("SELECT TIMESTAMP_MS '2026-11-07 12:34:56.789'", seconds(Double(1_794_054_896_789_000) / 1e6)),
        CellCase("SELECT TIMESTAMP_NS '2026-11-07 12:34:56.789012345'", seconds(Double(1_794_054_896_789_012) / 1e6)),
        CellCase("SELECT TIMESTAMP_NS '1969-12-31 23:59:59.999999999'", seconds(0)),
    ]

    @Test("TIMESTAMP in every unit, with time zone, before the epoch", arguments: timestamps)
    func timestampCells(_ test: CellCase) async throws {
        #expect(try await duckDBCell(test.sql) == test.expected)
    }

    @Test("a Date binds as a TIMESTAMP with microsecond precision and reads back identically")
    func dateBindRoundTrip() async throws {
        for instant in [0.0, 1_700_000_000.123456, -1.5, 1_794_054_896.789012, 253_402_214_400.0] {
            let date = Date(timeIntervalSince1970: instant)
            #expect(try await duckDBCell("SELECT $1", binds: [.date(date)]) == .date(date), "\(instant)")
        }
    }
}

// MARK: - Decimals

@Suite("Driver behaviour — decimal cells and binds, 128-bit extremes and scale")
struct DuckDBDecimalBehaviourTests {
    // One case per internal storage width (16, 32, 64, 128 bit), then the 38-digit extremes DuckDB allows.
    static let decimals: [CellCase] = [
        CellCase("SELECT '1.5'::DECIMAL(4,1)", decimal("1.5")),
        CellCase("SELECT '-1.5'::DECIMAL(4,1)", decimal("-1.5")),
        CellCase("SELECT '123.456'::DECIMAL(9,3)", decimal("123.456")),
        CellCase("SELECT '-123.456'::DECIMAL(9,3)", decimal("-123.456")),
        CellCase("SELECT '123456.123456'::DECIMAL(18,6)", decimal("123456.123456")),
        CellCase("SELECT '-999999999999.999999'::DECIMAL(18,6)", decimal("-999999999999.999999")),
        CellCase("SELECT '0.0000000001'::DECIMAL(38,10)", decimal("0.0000000001")),
        CellCase("SELECT '1234567890123456789012345.678901234567'::DECIMAL(38,12)", decimal("1234567890123456789012345.678901234567")),
        CellCase("SELECT '99999999999999999999999999999999999999'::DECIMAL(38,0)", decimal("99999999999999999999999999999999999999")),
        CellCase("SELECT '-99999999999999999999999999999999999999'::DECIMAL(38,0)", decimal("-99999999999999999999999999999999999999")),
        CellCase("SELECT '12345678901234567890123456789012345678'::DECIMAL(38,0)", decimal("12345678901234567890123456789012345678")),
        CellCase("SELECT '0.99999999999999999999999999999999999999'::DECIMAL(38,38)", decimal("0.99999999999999999999999999999999999999")),
        CellCase("SELECT '-0.99999999999999999999999999999999999999'::DECIMAL(38,38)", decimal("-0.99999999999999999999999999999999999999")),
        CellCase("SELECT '0.00000000000000000000000000000000000001'::DECIMAL(38,38)", decimal("0.00000000000000000000000000000000000001")),
        CellCase("SELECT '1000000000000000000000000000000'::DECIMAL(38,0)", decimal("1000000000000000000000000000000")),
        CellCase("SELECT '100'::DECIMAL(18,0)", decimal("100")),
        CellCase("SELECT '0.00'::DECIMAL(10,2)", decimal("0")),
        CellCase("SELECT '18446744073709551616'::DECIMAL(38,0)", decimal("18446744073709551616")),
        CellCase("SELECT '18446744073709551615'::DECIMAL(38,0)", decimal("18446744073709551615")),
    ]

    @Test("DECIMAL(w, s) reads as an exact Foundation Decimal", arguments: decimals)
    func decimalCells(_ test: CellCase) async throws {
        #expect(try await duckDBCell(test.sql) == test.expected)
    }

    @Test("a 38-digit decimal keeps every digit (compared as text, not just by value)")
    func decimalDigitsAreExact() async throws {
        let text = "12345678901234567890123456789012345678"
        guard case .decimal(let value) = try await duckDBCell("SELECT '\(text)'::DECIMAL(38,0)") else {
            Issue.record("not a decimal")
            return
        }
        #expect(value.description == text)
        guard case .decimal(let scaled) = try await duckDBCell("SELECT '-0.12345678901234567890123456789012345678'::DECIMAL(38,38)") else {
            Issue.record("not a decimal")
            return
        }
        #expect(scaled.description == "-0.12345678901234567890123456789012345678")
    }

    @Test("a column keeps its own scale: 1.50 and 1.5 are the same value")
    func scaleDoesNotChangeTheValue() async throws {
        #expect(try await duckDBCell("SELECT '1.50'::DECIMAL(10,2)") == decimal("1.5"))
    }

    // What `SELECT $1` gives back for a bound `Decimal`: the same value, as a DECIMAL. Zero is the one exception: it
    // is bound as the integer 0 (see `DuckDBDecimalParts`: duckdb-swift aborts the process on a zero decimal).
    static let boundDecimals: [String] = [
        "1.5", "-1.5", "100", "-100", "1e30", "1000000000000000000000000000000", "0.0000000001", "123.456",
        "12345678901234567890123456789012345678", "-12345678901234567890123456789012345678",
        "99999999999999999999999999999999999999", "-99999999999999999999999999999999999999",
        "0.99999999999999999999999999999999999999", "-0.99999999999999999999999999999999999999",
        "0.00000000000000000000000000000000000001", "18446744073709551616", "-18446744073709551615",
    ]

    @Test("a bound Decimal arrives unchanged (100 is 100, 1e30 is 1e30)", arguments: boundDecimals)
    func decimalBindRoundTrip(_ text: String) async throws {
        let value = try #require(Decimal(string: text))
        #expect(try await duckDBCell("SELECT $1", binds: [.decimal(value)]) == .decimal(value))
    }

    @Test("a bound Decimal compares equal to the stored column value")
    func decimalBindMatchesStoredValue() async throws {
        try await withDuckDBEngine { engine in
            _ = try await engine.run(sql: "CREATE TABLE prices (id INTEGER, amount DECIMAL(38,6))", binds: [])
            for (id, text) in [(1, "100"), (2, "1000000000000"), (3, "0.000001"), (4, "-7.25"), (5, "0")] {
                let value = try #require(Decimal(string: text))
                _ = try await engine.run(sql: "INSERT INTO prices VALUES ($1, $2)", binds: [.int(Int64(id)), .decimal(value)])
            }
            for (id, text) in [(1, "100"), (2, "1000000000000"), (3, "0.000001"), (4, "-7.25"), (5, "0")] {
                let value = try #require(Decimal(string: text))
                let found = try await engine.run(sql: "SELECT id FROM prices WHERE amount = $1", binds: [.decimal(value)])
                #expect(found.map(\.values) == [[.int(Int64(id))]], "amount = \(text)")
            }
        }
    }

    @Test("zero binds as the integer 0, on both drivers")
    func zeroDecimalBind() async throws {
        #expect(try await duckDBCell("SELECT $1", binds: [.decimal(0)]) == .int(0))
        #expect(try await duckDBCell("SELECT $1", binds: [.decimal(Decimal(string: "0.000")!)]) == .int(0))
    }

    @Test("a decimal DuckDB cannot hold is refused, never rounded or truncated")
    func unrepresentableDecimalsAreRefused() async throws {
        let tooManyDigits = try #require(Decimal(string: "123456789012345678901234567890123456789"))  // 39 digits
        let tooFine = try #require(Decimal(string: "0.000000000000000000000000000000000000001"))  // scale 39
        let tooBig = Decimal(sign: .plus, exponent: 60, significand: 1)
        for value in [tooManyDigits, tooFine, tooBig, Decimal.nan] {
            await #expect(throws: DuckDBSQLError.self, "\(value)") {
                _ = try await duckDBCell("SELECT $1", binds: [.decimal(value)])
            }
        }
    }
}

// MARK: - NULLs, chunks, result shape

@Suite("Driver behaviour — NULLs, many rows, result shape")
struct DuckDBResultShapeBehaviourTests {
    static let nullTypes = [
        "BOOLEAN", "TINYINT", "SMALLINT", "INTEGER", "BIGINT", "UTINYINT", "USMALLINT", "UINTEGER", "UBIGINT", "HUGEINT", "UHUGEINT",
        "FLOAT", "DOUBLE", "DECIMAL(4,1)", "DECIMAL(9,3)", "DECIMAL(18,6)", "DECIMAL(38,10)", "VARCHAR", "BLOB", "UUID", "DATE",
        "TIMESTAMP", "TIMESTAMPTZ", "TIMESTAMP_S", "TIMESTAMP_MS", "TIMESTAMP_NS",
    ]

    @Test("NULL of every decoded type is .null", arguments: nullTypes)
    func nullCells(_ type: String) async throws {
        #expect(try await duckDBCell("SELECT NULL::\(type)") == .null)
    }

    @Test("an untyped NULL is .null")
    func untypedNull() async throws {
        #expect(try await duckDBCell("SELECT NULL") == .null)
    }

    @Test("NULLs and values mix inside one column and one row")
    func mixedNulls() async throws {
        let rows = try await duckDBRows("""
            SELECT * FROM (VALUES (1, 'a', 1.5::DECIMAL(4,1)), (NULL, 'b', NULL), (3, NULL, 3.5::DECIMAL(4,1)), (NULL, NULL, NULL)) t(i, s, d)
            """)
        #expect(rows.map(\.values) == [
            [.int(1), .string("a"), decimal("1.5")],
            [.null, .string("b"), .null],
            [.int(3), .null, decimal("3.5")],
            [.null, .null, .null],
        ])
        #expect(rows.first?.columns == ["i", "s", "d"])
    }

    @Test("a result spanning several vectors (2048 rows each) is read whole, in order, NULLs in place")
    func manyRows() async throws {
        let rows = try await duckDBRows("""
            SELECT i::BIGINT AS i, CASE WHEN i % 3 = 0 THEN NULL ELSE i::VARCHAR END AS s, i::DECIMAL(18,2) AS d,
                   CASE WHEN i % 5 = 0 THEN NULL ELSE i::DOUBLE END AS f
            FROM range(6000) t(i)
            """)
        #expect(rows.count == 6000)
        for index in [0, 1, 2, 3, 2046, 2047, 2048, 2049, 4095, 4096, 4097, 5999] {
            let row = rows[index]
            #expect(row.values[0] == .int(Int64(index)), "row \(index) i")
            #expect(row.values[1] == (index % 3 == 0 ? .null : .string(String(index))), "row \(index) s")
            #expect(row.values[2] == .decimal(Decimal(index)), "row \(index) d")
            #expect(row.values[3] == (index % 5 == 0 ? .null : .double(Double(index))), "row \(index) f")
        }
        #expect(rows.map(\.values[0]) == (0..<6000).map { .int(Int64($0)) })
    }

    @Test("a large integer result is read completely")
    func hundredThousandRows() async throws {
        let rows = try await duckDBRows("SELECT i::BIGINT AS i FROM range(100000) t(i)")
        #expect(rows.count == 100_000)
        var sum: Int64 = 0
        for row in rows {
            if case .int(let value) = row.values[0] { sum += value }
        }
        #expect(sum == 100_000 * 99_999 / 2)
    }

    @Test("a query with no rows gives no rows")
    func noRows() async throws {
        #expect(try await duckDBRows("SELECT 1 AS a WHERE false").isEmpty)
    }

    @Test("columns keep their names and order")
    func columnNames() async throws {
        let rows = try await duckDBRows("SELECT 1 AS first, 'x' AS \"second col\", NULL AS third")
        #expect(rows.first?.columns == ["first", "second col", "third"])
        #expect(rows.first?.values == [.int(1), .string("x"), .null])
    }

    @Test("INSERT, UPDATE and DELETE report no rows, and RETURNING gives them")
    func dmlRows() async throws {
        try await withDuckDBEngine { engine in
            _ = try await engine.run(sql: "CREATE TABLE t (id INTEGER PRIMARY KEY, name VARCHAR)", binds: [])
            #expect(try await engine.run(sql: "INSERT INTO t VALUES (1, 'a'), (2, 'b')", binds: []).isEmpty)
            #expect(try await engine.run(sql: "UPDATE t SET name = 'z' WHERE id = 1", binds: []).isEmpty)
            #expect(try await engine.run(sql: "DELETE FROM t WHERE id = 2", binds: []).isEmpty)
            let returned = try await engine.run(sql: "INSERT INTO t VALUES (3, 'c') RETURNING id, name", binds: [])
            #expect(returned.map(\.values) == [[.int(3), .string("c")]])
            let all = try await engine.run(sql: "SELECT id, name FROM t ORDER BY id", binds: [])
            #expect(all.map(\.values) == [[.int(1), .string("z")], [.int(3), .string("c")]])
        }
    }

    @Test("every bind kind reaches DuckDB as its own kind")
    func bindKinds() async throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000.5)
        let cell = try await duckDBRows(
            "SELECT $1, $2, $3, $4, $5, $6, $7, $8",
            binds: [.null, .bool(true), .int(Int64.min), .double(-0.5), decimal("12.5"), .string("s"), .blob(Data([1, 2])), .date(date)]
        )
        #expect(cell.first?.values == [.null, .bool(true), .int(Int64.min), .double(-0.5), decimal("12.5"), .string("s"), .blob(Data([1, 2])), .date(date)])
    }
}
