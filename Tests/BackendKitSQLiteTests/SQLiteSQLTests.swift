import BackendKitSQL
import BackendKitSQLite
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

// SQLKit's own driver-conformance suite against the SQLite driver (spec b4f8c3a1 W2 gate).
final class SQLiteBenchmarkTests: XCTestCase {
    func testSQLiteDriverConformance() async throws {
        let host = try await SQLiteSQLHost.open(storage: .memory)
        do {
            try await SQLBenchmarker(on: host.database).runAllTests()
        } catch {
            try? await host.shutdown()
            throw error
        }
        try await host.shutdown()
    }
}

@Suite("SQLRepository — SQLite round-trip (no server needed)")
struct SQLiteRepositoryTests {
    static let hostile = "x'); DROP TABLE notes; --"

    private func roundTrip(_ host: SQLiteSQLHost) async throws {
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
        let host = try await SQLiteSQLHost.open(storage: .memory)
        do { try await roundTrip(host) } catch { try? await host.shutdown(); throw error }
        try await host.shutdown()
    }

    @Test("file-backed: round-trip, and data persists across a reopen")
    func file() async throws {
        let path = NSTemporaryDirectory() + "backendkit-sqlite-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let host = try await SQLiteSQLHost.open(storage: .file(path: path))
        do { try await roundTrip(host) } catch { try? await host.shutdown(); throw error }
        let repo = SQLRepository<UUID, Note>(database: host.database, table: "notes")
        let kept = Note(id: UUID(), title: Self.hostile, count: 1)
        try await repo.save(kept.id, data: kept)
        try await host.shutdown()

        let reopened = try await SQLiteSQLHost.open(storage: .file(path: path))
        let again = SQLRepository<UUID, Note>(database: reopened.database, table: "notes")
        #expect(try await again.get(kept.id) == kept)
        try await reopened.shutdown()
    }
}

struct PriceKey: Codable, Hashable, Sendable {
    let providerId: String
    let modelId: String
}

struct Price: Codable, Equatable, Sendable {
    let providerId: String
    let modelId: String
    let amount: String
}

@Suite("SQLRepository — composite key, read-only open, journal mode, constraint (consumer-driven, shikki W2)")
struct SQLiteConsumerDrivenTests {
    private func expectFailure(_ work: () async throws -> Void) async {
        do {
            try await work()
            Issue.record("expected the call to fail")
        } catch {}
    }

    private func createNotes(_ host: SQLiteSQLHost) async throws {
        let primary: SQLColumnConstraintAlgorithm = .primaryKey
        let builder = host.database.create(table: "notes")
        builder.column("id", type: .text, primary)
        builder.column("title", type: .text, .notNull)
        builder.column("count", type: .int, .notNull)
        try await builder.run()
    }

    private func tempPath() -> String {
        NSTemporaryDirectory() + "backendkit-sqlite-\(UUID().uuidString).db"
    }

    @Test("a composite key addresses, upserts and deletes by every key column")
    func compositeKey() async throws {
        let host = try await SQLiteSQLHost.open(storage: .memory)
        try await host.database.create(table: "prices")
            .column("providerId", type: .text, .notNull)
            .column("modelId", type: .text, .notNull)
            .column("amount", type: .text, .notNull)
            .primaryKey("providerId", "modelId")
            .run()
        let repo = SQLRepository<PriceKey, Price>(database: host.database, table: "prices", keyColumns: ["providerId", "modelId"])
        let a = Price(providerId: "p", modelId: "m1", amount: "1")
        let b = Price(providerId: "p", modelId: "m2", amount: "2")
        try await repo.save(PriceKey(providerId: "p", modelId: "m1"), data: a)
        try await repo.save(PriceKey(providerId: "p", modelId: "m2"), data: b)
        try await repo.save(PriceKey(providerId: "p", modelId: "m1"), data: Price(providerId: "p", modelId: "m1", amount: "9"))
        #expect(try await repo.list().count == 2)
        #expect(try await repo.get(PriceKey(providerId: "p", modelId: "m1")).amount == "9")
        #expect(try await repo.get(PriceKey(providerId: "p", modelId: "m2")) == b)
        try await repo.delete(PriceKey(providerId: "p", modelId: "m1"))
        #expect(try await repo.list() == [b])
        await #expect(throws: SQLRepositoryError.self) { _ = try await repo.get(PriceKey(providerId: "p", modelId: "m1")) }
        try await host.shutdown()
    }

    @Test("a composite key whose columns are not the key columns is refused")
    func keyMismatch() async throws {
        let host = try await SQLiteSQLHost.open(storage: .memory)
        let repo = SQLRepository<PriceKey, Price>(database: host.database, table: "prices", keyColumns: ["providerId", "other"])
        await #expect(throws: SQLRepositoryError.self) { _ = try await repo.get(PriceKey(providerId: "p", modelId: "m")) }
        try await host.shutdown()
    }

    @Test("readOnlyFile reads an existing database and the engine refuses a write; a missing file does not appear")
    func readOnly() async throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let writer = try await SQLiteSQLHost.open(storage: .file(path: path))
        try await createNotes(writer)
        let id = UUID()
        try await SQLRepository<UUID, Note>(database: writer.database, table: "notes").save(id, data: Note(id: id, title: "t", count: 1))
        try await writer.shutdown()

        let reader = try await SQLiteSQLHost.open(storage: .readOnlyFile(path: path))
        let repo = SQLRepository<UUID, Note>(database: reader.database, table: "notes")
        #expect(try await repo.get(id).title == "t")
        await expectFailure { try await repo.save(id, data: Note(id: id, title: "x", count: 2)) }
        try await reader.shutdown()

        let missing = tempPath()
        await expectFailure { _ = try await SQLiteSQLHost.open(storage: .readOnlyFile(path: missing)) }
        #expect(!FileManager.default.fileExists(atPath: missing))
    }

    @Test("journalMode .wal is applied to a file database")
    func wal() async throws {
        let path = tempPath()
        defer {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
        }
        let host = try await SQLiteSQLHost.open(storage: .file(path: path), journalMode: .wal)
        let row = try await host.database.raw("PRAGMA journal_mode").first()
        #expect(try row?.decode(column: "journal_mode", as: String.self).lowercased() == "wal")
        try await host.shutdown()
    }

    @Test("a host released without shutdown() closes its connection (no SQLiteNIO deinit assertion)")
    func droppedHostCloses() async throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        do {
            let host = try await SQLiteSQLHost.open(storage: .file(path: path))
            try await createNotes(host)
        }
        try await Task.sleep(for: .milliseconds(200))
        let reopened = try await SQLiteSQLHost.open(storage: .readOnlyFile(path: path))
        try await reopened.shutdown()
        let again = try await SQLiteSQLHost.open(storage: .memory)
        try await again.shutdown()
        try await again.shutdown()
    }

    @Test("a duplicate primary key is recognised as a constraint violation, other errors are not")
    func constraint() async throws {
        let host = try await SQLiteSQLHost.open(storage: .memory)
        try await createNotes(host)
        let note = Note(id: UUID(), title: "t", count: 1)
        try await host.database.insert(into: "notes").model(note).run()
        do {
            try await host.database.insert(into: "notes").model(note).run()
            Issue.record("expected a constraint violation")
        } catch {
            #expect(SQLiteSQLHost.isConstraintViolation(error))
        }
        #expect(!SQLiteSQLHost.isConstraintViolation(SQLRepositoryError.notFound(idDescription: "x")))
        try await host.shutdown()
    }
}
