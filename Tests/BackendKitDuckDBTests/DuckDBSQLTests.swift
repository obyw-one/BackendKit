#if BACKENDKIT_DUCKDB
import BackendKitDuckDB
import BackendKitSQL
import CoreKitTestSupport
import Foundation
import SQLKit
import SQLKitBenchmark
import Testing
import XCTest

struct Note: Codable, Equatable, Sendable {
    let id: UUID
    let title: String
    let count: Int
}

// SQLKit's own driver-conformance suite against the DuckDB driver (spec b4f8c3a1 W3 gate).
// `SQLBenchmarker.runAllTests()` = testPlanets + testCodable + testEnum + testUpserts +
// testUnions + testJSONPaths. Each public sub-suite runs on its own so a failure names itself.
// `testPlanets` is NOT run here; re-verified on DuckDB 2.1.0-dev84836 it still fails on two DuckDB-by-design points:
// `SELECT * ... GROUP BY id` (no PK functional dependency; Binder Error) and `ALTER TABLE DROP COLUMN` after an index
// (Dependency Error). `ADD COLUMN` after an index is accepted on 2.x. `DuckDBPlanetsEquivalentTests` replays the rest.
final class DuckDBBenchmarkTests: XCTestCase {
    private func withHost(_ body: (SQLBenchmarker) async throws -> Void) async throws {
        let host = try await DuckDBSQLHost.open(storage: .memory)
        do {
            try await body(SQLBenchmarker(on: host.database))
        } catch {
            try? await host.shutdown()
            throw error
        }
        try await host.shutdown()
    }

    func testCodableConformance() async throws { try await withHost { try await $0.testCodable() } }
    func testEnumConformance() async throws { try await withHost { try await $0.testEnum() } }
    func testUpsertConformance() async throws { try await withHost { try await $0.testUpserts() } }
    func testUnionConformance() async throws { try await withHost { try await $0.testUnions() } }
    func testJSONPathsConformance() async throws { try await withHost { try await $0.testJSONPaths() } }
}

// `testPlanets` minus its one `GROUP BY id` over `SELECT *` (DuckDB has no functional-dependency
// grouping): schema create/alter/index, DEFAULT-key inserts, binds, counts.
final class DuckDBPlanetsEquivalentTests: XCTestCase {
    func testPlanetsEquivalent() async throws {
        let host = try await DuckDBSQLHost.open(storage: .memory)
        do { try await run(host.database) } catch { try? await host.shutdown(); throw error }
        try await host.shutdown()
    }

    private func run(_ db: any SQLDatabase) async throws {
        try await db.drop(table: "planets").ifExists().run()
        try await db.drop(table: "galaxies").ifExists().run()
        try await db.create(table: "galaxies").column("id", type: .bigint, .primaryKey).column("name", type: .text).run()
        try await db.create(table: "planets").ifNotExists()
            .column("id", type: .bigint, .primaryKey)
            .column("galaxyID", type: .bigint, .references("galaxies", "id"))
            .run()
        try await db.alter(table: "planets").column("name", type: .text, .default(SQLLiteral.string("Unnamed Planet"))).run()
        // DuckDB refuses DROP COLUMN once an index depends on the table (still true on 2.x), so the drop
        // happens before the index; ADD COLUMN after the unique index is accepted on 2.x, as in SQLKit's testPlanets.
        try await db.alter(table: "planets").column("extra", type: .int).run()
        try await db.alter(table: "planets").dropColumn("extra").run()
        try await db.create(index: "test_index").on("planets").column("id").unique().run()
        try await db.alter(table: "planets").column("late", type: .int).run()

        try await db.insert(into: "galaxies").columns("id", "name")
            .values(SQLLiteral.default, SQLBind("Milky Way"))
            .values(SQLLiteral.default, SQLBind("Andromeda"))
            .run()
        let found = try await db.select().column("*").from("galaxies")
            .where("name", .notEqual, SQLLiteral.null)
            .where { $0.where("name", .equal, SQLBind("Milky Way")).orWhere("name", .equal, SQLBind("Andromeda")) }
            .all()
        // `name != NULL` is never true in SQL (three-valued logic), on every engine: 0 rows, not 2.
        XCTAssertEqual(found.count, 0)
        let ordered = try await db.select().column("*").from("galaxies")
            .where(SQLColumn("name"), .equal, SQLBind("Milky Way"))
            .orderBy("name", .descending)
            .all()
        XCTAssertEqual(ordered.count, 1)

        try await db.insert(into: "planets").columns("id", "name").values(SQLLiteral.default, SQLBind("Earth")).run()
        try await db.insert(into: "planets").columns("id", "name")
            .values(SQLLiteral.default, SQLBind("Mercury"))
            .values(SQLLiteral.default, SQLBind("Venus"))
            .run()
        let counted = try await db.select().column(SQLFunction("count", args: SQLLiteral.all)).from("planets").all()
        XCTAssertEqual(try counted.first?.decode(column: "count_star()", as: Int.self), 3)

        try await db.drop(table: "planets").run()
        try await db.drop(table: "galaxies").run()
    }
}

@Suite("SQLRepository — DuckDB round-trip (no server needed)")
struct DuckDBRepositoryTests {
    private static let scratch = TestScratch.forPackage()

    static let hostile = "x'); DROP TABLE notes; --"

    private func roundTrip(_ host: DuckDBSQLHost) async throws {
        try await host.database.raw("CREATE TABLE notes (id TEXT PRIMARY KEY, title TEXT NOT NULL, count INTEGER NOT NULL)").run()
        let repo = SQLRepository<UUID, Note>(database: host.database, table: "notes")
        let note = Note(id: UUID(), title: Self.hostile, count: 7)
        try await repo.save(note.id, data: note)
        #expect(try await repo.get(note.id) == note)

        let updated = Note(id: note.id, title: "renamed", count: 8)
        try await repo.save(updated.id, data: updated)
        #expect(try await repo.list() == [updated])

        // Hostile string stored and read back as data; the table survived.
        try await repo.save(note.id, data: note)
        #expect(try await repo.get(note.id).title == Self.hostile)

        try await repo.delete(note.id)
        await #expect(throws: SQLRepositoryError.self) { _ = try await repo.get(note.id) }
        await #expect(throws: SQLRepositoryError.self) { try await repo.delete(note.id) }
    }

    @Test("in-memory: save / get / list / delete + hostile string as data")
    func memory() async throws {
        let host = try await DuckDBSQLHost.open(storage: .memory)
        do { try await roundTrip(host) } catch { try? await host.shutdown(); throw error }
        try await host.shutdown()
    }

    @Test("file-backed: round-trip, and data persists across a reopen")
    func file() async throws {
        // Under the package's own `.tests/` (CoreKit `TestScratch`), never `NSTemporaryDirectory()`.
        let directory = try Self.scratch.makeScratchDir(scope: "duckdb")
        defer { try? Self.scratch.removeScratchDir(directory) }
        let path = directory.appendingPathComponent("backendkit-duckdb.db").path
        let host = try await DuckDBSQLHost.open(storage: .file(path: path))
        do { try await roundTrip(host) } catch { try? await host.shutdown(); throw error }
        let repo = SQLRepository<UUID, Note>(database: host.database, table: "notes")
        let kept = Note(id: UUID(), title: Self.hostile, count: 1)
        try await repo.save(kept.id, data: kept)
        try await host.shutdown()

        let reopened = try await DuckDBSQLHost.open(storage: .file(path: path))
        let again = SQLRepository<UUID, Note>(database: reopened.database, table: "notes")
        #expect(try await again.get(kept.id) == kept)
        try await reopened.shutdown()
    }
}

/// A typed event, ingested as JSONL and analysed in DuckDB (the engine's strength: columnar analytics over files).
struct Sale: Codable, Equatable, Sendable {
    let id: Int
    let category: String
    let amount: Double
}

/// The typed shape of the aggregate the analytical query returns.
struct CategoryTotal: Codable, Equatable, Sendable {
    let category: String
    let sales: Int
    let average: Double
    let total: Double
}

@Suite("DuckDB — ingest typed Codable data as JSONL, then analyse it")
struct DuckDBAnalyticsTests {
    private static let scratch = TestScratch.forPackage()

    @Test("JSONL of a Codable list -> read_json_auto -> GROUP BY category -> typed aggregate")
    func ingestJSONLAndAggregate() async throws {
        let sales = [
            Sale(id: 1, category: "books", amount: 10),
            Sale(id: 2, category: "books", amount: 30),
            Sale(id: 3, category: "games", amount: 50),
            Sale(id: 4, category: "books", amount: 20),
            Sale(id: 5, category: "games", amount: 70),
        ]
        // One JSON object per line: the format DuckDB reads natively.
        let encoder = JSONEncoder()
        let lines = try sales.map { try #require(String(bytes: try encoder.encode($0), encoding: .utf8)) }
        let jsonl = lines.joined(separator: "\n")
        let directory = try Self.scratch.makeScratchDir(scope: "duckdb")
        defer { try? Self.scratch.removeScratchDir(directory) }
        let path = directory.appendingPathComponent("backendkit-sales.jsonl").path
        try jsonl.write(toFile: path, atomically: true, encoding: .utf8)

        let host = try await DuckDBSQLHost.open(storage: .memory)
        do {
            try await host.database.raw("CREATE TABLE sales AS SELECT * FROM read_json_auto(\(bind: path))").run()
            let totals = try await host.database.raw("""
                SELECT category, COUNT(*) AS sales, AVG(amount) AS average, SUM(amount) AS total \
                FROM sales GROUP BY category ORDER BY category
                """).all(decoding: CategoryTotal.self)
            #expect(totals == [
                CategoryTotal(category: "books", sales: 3, average: 20, total: 60),
                CategoryTotal(category: "games", sales: 2, average: 60, total: 120),
            ])
        } catch {
            try? await host.shutdown()
            throw error
        }
        try await host.shutdown()
    }
}
#endif
