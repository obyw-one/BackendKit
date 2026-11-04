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
