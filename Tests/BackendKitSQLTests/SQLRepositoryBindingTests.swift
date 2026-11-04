import Foundation
import Logging
import NIOCore
import NIOPosix
import SQLKit
import Testing
@testable import BackendKitSQL

// MARK: - RecordingDatabase

/// A driver-less `SQLDatabase` that serializes every query the way a real driver
/// would and records the SQL text and the bound values — the evidence for BR-SQL-01.
final class RecordingDatabase: SQLDatabase, @unchecked Sendable {
    struct Recorded { let sql: String; let binds: [any Encodable & Sendable] }
    private let lock = NSLock()
    private var storage: [Recorded] = []
    var recorded: [Recorded] { lock.withLock { storage } }

    let logger = Logger(label: "backendkit.sql.recording")
    var eventLoop: any EventLoop { MultiThreadedEventLoopGroup.singleton.next() }
    var version: (any SQLDatabaseReportedVersion)? { nil }
    var dialect: any SQLDialect { TestDialect() }

    func execute(sql query: any SQLExpression, _ onRow: @escaping @Sendable (any SQLRow) -> Void) -> EventLoopFuture<Void> {
        var serializer = SQLSerializer(database: self)
        query.serialize(to: &serializer)
        lock.withLock { storage.append(Recorded(sql: serializer.sql, binds: serializer.binds)) }
        return eventLoop.makeSucceededFuture(())
    }
}

struct TestDialect: SQLDialect {
    var name: String { "test" }
    var identifierQuote: any SQLExpression { SQLRaw("\"") }
    var literalStringQuote: any SQLExpression { SQLRaw("'") }
    func bindPlaceholder(at position: Int) -> any SQLExpression { SQLRaw("$\(position)") }
    func literalBoolean(_ value: Bool) -> any SQLExpression { SQLRaw(value ? "true" : "false") }
    var supportsAutoIncrement: Bool { true }
    var autoIncrementClause: any SQLExpression { SQLRaw("AUTOINCREMENT") }
}

// MARK: - Fixture

struct Note: Codable, Equatable, Sendable {
    let id: UUID
    let title: String
    let count: Int
}

// MARK: - Tests

@Suite("SQLRepository — values bind, never interpolate (BR-SQL-01)")
struct SQLRepositoryBindingTests {
    static let hostile = "x'); DROP TABLE notes; --"

    @Test("save: a hostile string is a bound parameter, absent from the SQL text")
    func saveBindsHostileString() async throws {
        let db = RecordingDatabase()
        let repo = SQLRepository<UUID, Note>(database: db, table: "notes")
        let note = Note(id: UUID(), title: Self.hostile, count: 3)
        try await repo.save(note.id, data: note)

        let query = try #require(db.recorded.first)
        #expect(!query.sql.contains("DROP TABLE"))
        #expect(!query.sql.contains(Self.hostile))
        #expect(query.sql.contains("INSERT INTO"))
        let strings = query.binds.compactMap { $0 as? String }
        #expect(strings.contains(Self.hostile))
    }

    @Test("get / delete: the id is a bound parameter, not text")
    func lookupBindsId() async throws {
        let db = RecordingDatabase()
        let repo = SQLRepository<UUID, Note>(database: db, table: "notes")
        let id = UUID()
        _ = try? await repo.get(id)
        _ = try? await repo.delete(id)
        #expect(db.recorded.count == 2)
        for query in db.recorded {
            #expect(!query.sql.contains(id.uuidString))
            #expect(!query.binds.isEmpty)
        }
    }
}
