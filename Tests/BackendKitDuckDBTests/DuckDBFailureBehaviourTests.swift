import CoreKitTestSupport
import Foundation
import Testing

@testable import BackendKitDuckDB

// MARK: - DuckDBFailureBehaviourTests

//
// The other half of the one behaviour suite (see DuckDBTypeBehaviourTests): what a failure looks like, what is
// refused instead of dropped, and the lifecycle. Compiled unchanged on every platform; both drivers must throw the same
// type (`DuckDBSQLError`), carry DuckDB's own text, and release the database when asked.

/// The message of a thrown `DuckDBSQLError.engine`, or a recorded issue when anything else (or nothing) is thrown.
private func engineMessage(_ work: () async throws -> Void) async -> String? {
    do {
        try await work()
        Issue.record("expected DuckDBSQLError.engine, nothing was thrown")
    } catch DuckDBSQLError.engine(let message) {
        return message
    } catch {
        Issue.record("expected DuckDBSQLError.engine, got \(error)")
    }
    return nil
}

@Suite("Driver behaviour — failures carry DuckDB's own text")
struct DuckDBErrorBehaviourTests {
    struct FailureCase: Sendable, CustomTestStringConvertible {
        let sql: String
        let fragment: String
        var testDescription: String { sql }
    }

    // The fragment is the error CLASS DuckDB prefixes to its message, which both versions share.
    static let failures: [FailureCase] = [
        FailureCase(sql: "SELEC 1", fragment: "Parser Error"),
        FailureCase(sql: "SELECT * FROM no_such_table_anywhere", fragment: "Catalog Error"),
        FailureCase(sql: "SELECT no_such_function_anywhere(1)", fragment: "Catalog Error"),
        FailureCase(sql: "SELECT 'abc'::INTEGER", fragment: "Conversion Error"),
        FailureCase(sql: "SELECT error('boom from error()')", fragment: "boom from error()"),
        FailureCase(sql: "SELECT 1; SELECT 2", fragment: "multiple statements"),
    ]

    @Test("a statement DuckDB rejects throws .engine with DuckDB's message", arguments: failures)
    func statementFailures(_ test: FailureCase) async throws {
        let message = await engineMessage { _ = try await duckDBRows(test.sql) }
        #expect(message?.contains(test.fragment) == true, "message was: \(message ?? "none")")
    }

    @Test("a constraint violation throws .engine and leaves the database usable")
    func constraintViolation() async throws {
        try await withDuckDBEngine { engine in
            _ = try await engine.run(sql: "CREATE TABLE k (id INTEGER PRIMARY KEY)", binds: [])
            _ = try await engine.run(sql: "INSERT INTO k VALUES ($1)", binds: [.int(1)])
            let message = await engineMessage { _ = try await engine.run(sql: "INSERT INTO k VALUES ($1)", binds: [.int(1)]) }
            #expect(message?.contains("Constraint Error") == true, "message was: \(message ?? "none")")
            let count = try await engine.run(sql: "SELECT count(*) FROM k", binds: [])
            #expect(count.first?.values == [.int(1)])
        }
    }

    @Test("a failed statement does not poison the next one")
    func failureThenSuccess() async throws {
        try await withDuckDBEngine { engine in
            for _ in 0..<5 {
                _ = await engineMessage { _ = try await engine.run(sql: "SELEC", binds: []) }
                let seven = try await engine.run(sql: "SELECT 7", binds: [])
                #expect(seven.first?.values == [.int(7)])
            }
        }
    }

    @Test("binding more values than the statement has parameters throws .engine")
    func tooManyBinds() async throws {
        let message = await engineMessage { _ = try await duckDBRows("SELECT 1", binds: [.int(1), .int(2)]) }
        #expect(message?.isEmpty == false)
    }

    @Test("binding fewer values than the statement has parameters throws .engine")
    func tooFewBinds() async throws {
        let message = await engineMessage { _ = try await duckDBRows("SELECT $1, $2", binds: [.int(1)]) }
        #expect(message?.isEmpty == false)
    }

    @Test("a bound value of the wrong type for its use throws .engine")
    func wrongBindType() async throws {
        let message = await engineMessage { _ = try await duckDBRows("SELECT $1::DATE", binds: [.string("not a date")]) }
        #expect(message?.contains("Conversion Error") == true, "message was: \(message ?? "none")")
    }

    @Test("a file database that cannot be opened throws .engine at open")
    func unopenableFile() async throws {
        let scratch = TestScratch.forPackage()
        let directory = try scratch.makeScratchDir(scope: "duckdb")
        defer { try? scratch.removeScratchDir(directory) }
        let missing = directory.appendingPathComponent("no-such-directory").appendingPathComponent("db.duckdb").path
        let message = await engineMessage { _ = try await withDuckDBEngine(.file(path: missing)) { _ in () } }
        #expect(message?.isEmpty == false)
    }

    @Test("a file that is not a database throws .engine at open")
    func notADatabase() async throws {
        let scratch = TestScratch.forPackage()
        let directory = try scratch.makeScratchDir(scope: "duckdb")
        defer { try? scratch.removeScratchDir(directory) }
        let file = directory.appendingPathComponent("not-a-database.duckdb")
        try Data(repeating: 0x41, count: 4096).write(to: file)
        let message = await engineMessage { _ = try await withDuckDBEngine(.file(path: file.path)) { _ in () } }
        #expect(message?.isEmpty == false)
    }
}

@Suite("Driver behaviour — a column type that is not decoded is refused, never read as NULL")
struct DuckDBUnsupportedColumnBehaviourTests {
    struct TypeCase: Sendable, CustomTestStringConvertible {
        let expression: String
        /// What the error names, when the type has a stable SQL name on both drivers.
        let name: String?
        var testDescription: String { expression }
    }

    static let types: [TypeCase] = [
        TypeCase(expression: "TIME '12:00:00'", name: "TIME"),
        TypeCase(expression: "TIMETZ '12:00:00+00'", name: "TIME WITH TIME ZONE"),
        TypeCase(expression: "INTERVAL 1 DAY", name: "INTERVAL"),
        TypeCase(expression: "[1, 2]", name: "LIST"),
        TypeCase(expression: "{'a': 1}", name: "STRUCT"),
        TypeCase(expression: "MAP {'a': 1}", name: "MAP"),
        TypeCase(expression: "CAST('a' AS ENUM('a', 'b'))", name: "ENUM"),
        TypeCase(expression: "union_value(num := 1)", name: "UNION"),
        TypeCase(expression: "[1, 2]::INTEGER[2]", name: "ARRAY"),
        TypeCase(expression: "'101'::BIT", name: "BIT"),
    ]

    @Test("the query fails and names the column and the type", arguments: types)
    func refused(_ test: TypeCase) async throws {
        do {
            _ = try await duckDBRows("SELECT \(test.expression) AS c")
            Issue.record("\(test.expression) was returned instead of refused")
        } catch DuckDBSQLError.unsupportedColumnType(let column, let type) {
            #expect(column == "c")
            if let name = test.name { #expect(type == name) } else { #expect(!type.isEmpty) }
        } catch {
            Issue.record("expected unsupportedColumnType, got \(error)")
        }
    }

    @Test("it is refused by the shape of the query, also when no row comes back or the value is NULL", arguments: types)
    func refusedWithoutRows(_ test: TypeCase) async throws {
        await #expect(throws: DuckDBSQLError.self) { _ = try await duckDBRows("SELECT \(test.expression) AS c WHERE false") }
        await #expect(throws: DuckDBSQLError.self) { _ = try await duckDBRows("SELECT NULL::VARCHAR AS keep, \(test.expression) AS c") }
    }

    @Test("casting the column to VARCHAR is the documented way through")
    func castIsTheWayThrough() async throws {
        #expect(try await duckDBCell("SELECT CAST(TIME '12:34:56' AS VARCHAR)") == .string("12:34:56"))
        #expect(try await duckDBCell("SELECT CAST([1, 2] AS VARCHAR)") == .string("[1, 2]"))
    }
}

@Suite("Driver behaviour — lifecycle")
struct DuckDBLifecycleBehaviourTests {
    @Test("after close every statement throws .shutDown, and close is idempotent")
    func closed() async throws {
        let engine = try DuckDBEngine(storage: .memory)
        #expect(try await engine.run(sql: "SELECT 1", binds: []).count == 1)
        await engine.close()
        await engine.close()
        await #expect(throws: DuckDBSQLError.shutDown) { _ = try await engine.run(sql: "SELECT 1", binds: []) }
    }

    @Test("close releases a file database at once: it can be reopened while the old engine is still alive, and its data is there")
    func closeReleasesTheFile() async throws {
        let scratch = TestScratch.forPackage()
        let directory = try scratch.makeScratchDir(scope: "duckdb")
        defer { try? scratch.removeScratchDir(directory) }
        let path = directory.appendingPathComponent("lifecycle.duckdb").path

        let first = try DuckDBEngine(storage: .file(path: path))
        _ = try await first.run(sql: "CREATE TABLE kept (v INTEGER)", binds: [])
        _ = try await first.run(sql: "INSERT INTO kept VALUES ($1)", binds: [.int(42)])
        await first.close()

        let second = try DuckDBEngine(storage: .file(path: path))
        #expect(try await second.run(sql: "SELECT v FROM kept", binds: []).map(\.values) == [[.int(42)]])
        await second.close()
        _ = first  // still referenced here: the release came from close(), not from the engine being dropped.
    }

    @Test("an in-memory database is private to its engine")
    func memoryIsPrivate() async throws {
        try await withDuckDBEngine { one in
            _ = try await one.run(sql: "CREATE TABLE only_here (v INTEGER)", binds: [])
            try await withDuckDBEngine { two in
                await #expect(throws: DuckDBSQLError.self) { _ = try await two.run(sql: "SELECT * FROM only_here", binds: []) }
            }
        }
    }

    @Test("many concurrent callers are serialised by the engine: every insert lands exactly once")
    func concurrentCallers() async throws {
        try await withDuckDBEngine { engine in
            _ = try await engine.run(sql: "CREATE TABLE hits (id INTEGER PRIMARY KEY, label VARCHAR)", binds: [])
            try await withThrowingTaskGroup(of: Void.self) { group in
                for id in 0..<200 {
                    group.addTask {
                        _ = try await engine.run(sql: "INSERT INTO hits VALUES ($1, $2)", binds: [.int(Int64(id)), .string("row \(id)")])
                        let read = try await engine.run(sql: "SELECT label FROM hits WHERE id = $1", binds: [.int(Int64(id))])
                        #expect(read.first?.values == [.string("row \(id)")])
                    }
                }
                try await group.waitForAll()
            }
            let total = try await engine.run(sql: "SELECT count(*), sum(id) FROM hits", binds: [])
            // sum() of an INTEGER column is a HUGEINT, which is carried as text.
            #expect(total.first?.values == [.int(200), .string("19900")])
        }
    }

    @Test("many engines open and close without leaking or tripping over each other")
    func openCloseLoop() async throws {
        for index in 0..<50 {
            try await withDuckDBEngine { engine in
                let echoed = try await engine.run(sql: "SELECT $1", binds: [.int(Int64(index))])
                #expect(echoed.first?.values == [.int(Int64(index))])
            }
        }
    }
}
